# textfmt-headings: headings and lists from textutil's HTML (FMT13, part 2)

Slug `textfmt-headings`, branch `textfmt/headings` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## Why

textutil's HTML (another task runs textutil) gives every heading as a plain `<p>` in bold or a larger size, even from Word's Heading styles and OpenDocument's `text:h` (verified). It also writes the lists of .doc, .docx, and WordML files as literal tab, bullet, tab paragraphs, and names each picture by its attachment's file name. This task writes one pass over that HTML, before `HTMLToMarkdownConverter`, that restores headings (the research's route A), lists, and silence for pictures. It is a pure function on a parsed document: no file, no process, no format wiring.

The user's wish for bold and italic in body text: keep it if possible, for a future change that may speak differently formatted text differently. `HTMLToMarkdownConverter` already writes `<b>` and `<i>` as Markdown emphasis that the parser never speaks as symbols, so this pass must leave `b`, `i`, `strong`, and `em` in body text exactly as they are.

## Read first (by line range)

- `TextMouth/Parsers/HTMLToMarkdownConverter.swift` lines 1-45 (`convert(document:readingFlow:...)`, which takes a parsed document) and 144-200 (headings are written as literal labels; emphasis as `*`/`**`).
- `TextMouth/Parsers/HTMLReadingText.swift`: grep for `headingLevel` and `collapsingWhitespace`, and reuse what fits.
- `TextMouth/Parsers/PublicationSemantics.swift`: grep `struct ReadingFlow` and its `init(source:)`.

## textutil's HTML (verified on the samples)

Sizes live in class rules of the head's `<style>`, bold in `<b>` (and possibly in a class rule):

```html
<style type="text/css">
  p.p1 {margin: 0.0px 0.0px 16.1px 0.0px; font: 24.0px Times; -webkit-text-stroke: #000000}
  p.p2 {margin: 0.0px 0.0px 12.0px 0.0px; font: 12.0px Times; -webkit-text-stroke: #000000}
  p.p3 {margin: 0.0px 0.0px 14.9px 0.0px; font: 18.0px Times; -webkit-text-stroke: #000000}
  p.p4 {margin: 0.0px 0.0px 0.0px 36.0px; text-indent: -36.0px; font: 12.0px Times}
  li.li4 {margin: 0.0px 0.0px 0.0px 0.0px; font: 12.0px Times; -webkit-text-stroke: #000000}
  span.s1 {font-kerning: none}
  span.Apple-tab-span {white-space:pre}
</style>
...
<p class="p1"><span class="s1"><b>Harbour Notes</b></span></p>
<p class="p2"><span class="s1">The ferry leaves at seven. Café tables fill early, and the señor at the counter pours coffee without asking.</span></p>
<p class="p3"><span class="s1"><b>Morning Tides</b></span></p>
<p class="p4"><span class="Apple-tab-span">	</span>•<span class="Apple-tab-span">	</span>Bread from the bakery on Rue Ménard</p>
<p class="p2"><span class="s1"><img src="file:///Attachment.png" alt="Attachment.png"></span></p>
<table cellspacing="0" cellpadding="0" class="t1"><tbody><tr><td valign="middle" class="td1"><p class="p5"><span class="s1"><b>Boat</b></span></p></td>...</tr></tbody></table>
<ul class="ul1"><li class="li4"><span class="s1">Smoked fish, naïve prices</span></li></ul>
<p class="p8"><br></p>
```

A real Word file with Heading 1 to 6 (`doc/libreoffice-tdf104239_chapterNumbering.doc`) comes back as (use it as a test fixture, verbatim):

```html
<style type="text/css">
  p.p1 {margin: 12.0px 0.0px 6.0px 0.0px; font: 18.0px 'Times New Roman'}
  p.p2 {margin: 10.0px 0.0px 6.0px 0.0px; font: 16.0px 'Times New Roman'}
  p.p3 {margin: 7.0px 0.0px 6.0px 0.0px; font: 14.0px 'Times New Roman'}
  p.p4 {margin: 6.0px 0.0px 6.0px 0.0px; font: 13.5px 'Times New Roman'}
  p.p5 {margin: 6.0px 0.0px 3.0px 0.0px; font: 12.0px 'Times New Roman'}
  p.p6 {margin: 3.0px 0.0px 3.0px 0.0px; font: 12.0px 'Times New Roman'}
  p.p7 {margin: 0.0px 0.0px 0.0px 0.0px; text-align: center; font: 12.0px 'Times New Roman'}
  p.p8 {margin: 0.0px 0.0px 0.0px 0.0px; font: 12.0px 'Times New Roman'; min-height: 15.0px}
</style>
<body>
<p class="p1"><b>Heading 1</b></p>
<p class="p2"><b>Heading 2</b></p>
<p class="p3"><b>Heading 3</b></p>
<p class="p4"><b><i>Heading 4</i></b></p>
<p class="p5"><b>Heading 5</b></p>
<p class="p6"><b><i>Heading 6</i></b></p>
<p class="p7">Chapter numbering</p>
<p class="p8"><br></p>
<p class="p8"><b><i></i></b><br></p>
</body>
```

And an RTF written as Word writes it (`rtf/word-styles.rtf`):

```html
<style type="text/css">
  p.p1 {margin: 12.0px 0.0px 3.0px 0.0px; font: 16.0px Arial}
  p.p2 {margin: 0.0px 0.0px 0.0px 0.0px; font: 12.0px 'Times New Roman'}
  p.p3 {margin: 12.0px 0.0px 3.0px 0.0px; font: 14.0px Arial}
  p.p4 {margin: 0.0px 0.0px 0.0px 0.0px; font: 13.0px Arial}
  p.p5 {margin: 12.0px 0.0px 3.0px 0.0px; font: 13.0px Arial}
</style>
<body>
<p class="p1"><b>Chapter One: The Quay</b></p>
<p class="p2">The ferry leaves at seven. Café tables fill early, and the señor at the counter pours coffee without asking.</p>
<p class="p3"><b><i>Morning Tides</i></b></p>
<p class="p2">Gulls argue over crusts; the crane operators wave, and everyone says “good morning” in three languages. Prices – in euros – are posted by the quay. Unicode check: €5 and česky.</p>
<p class="p4"><b>A paragraph with outline level 3 but no heading style</b></p>
<p class="p5"><b>A third-level heading</b></p>
<p class="p2">The last paragraph is plain.</p>
</body>
```

## What to build

A new file `TextMouth/Parsers/TextutilHTMLStructure.swift`: `enum TextutilHTMLStructure` with `static func restore(in document: Document) throws`, which rewrites the SwiftSoup document in place. Keep each rule below in a small function of its own with a comment saying why.

1. **Class rules.** Read every `<style>` element's text. A rule is `tag.class { declarations }` (one class). Its size is `font-size: <n>px`, or else the first `<n>px` token of the `font` shorthand (it may read `<n>px/<line-height>`). It is bold when `font-weight` is `bold`, `bolder`, or a number of 600 or more, or when the `font` shorthand holds the word `bold`. Anything else in the rules is ignored. A document without styles has no class sizes.
2. **Each character's size and weight.** For every text node in `body` holding a character other than white space: its size is that of the nearest element, from the node up to its block, whose class rule gives a size, and 12 px when none does. It is bold when an element between it and its block is `b` or `strong`, or has a bold class rule. Characters are counted as `Character`s other than white space. A block is `p`, `li`, `td`, `th`, `h1` to `h6`, `div`, `blockquote`, or `pre`.
3. **Sizes compare to the half pixel** (13.5 and 13.4 are the same size; 13.5 and 14 are not): round each to the nearest 0.5 px once, in one helper.
4. **The body size** is the size holding the most characters in the whole body, tables and lists included; a tie goes to the smaller size.
5. **Candidates.** A `p` element is a candidate when it is not inside an `li`, `td`, `th`, `table`, `ul`, or `ol`; its text, white space collapsed and trimmed, is not empty, is at most 120 characters (a named constant), and is not a single letter (a decorative initial; a single digit, a chapter's number, stays a candidate); and either
   - **larger:** the size holding most of its own characters is above the body size, or
   - **bold:** every character of it is bold, at the body size, and the bold rule is on. The bold rule is off when more than half the body-size characters of the whole body are bold: a document in bold throughout has no headings from bold.
6. **Levels.** The distinct sizes of the larger candidates, largest first, give levels 1, 2, 3, and so on; every bold candidate takes the next level after them. No level passes 6: the smaller sizes share level 6. A paragraph that is not a candidate (a decorative letter, a long paragraph) takes no rank.
7. **Rewrite** each candidate `p` as `h<level>`, keeping its children; nothing else about it changes.
8. **Bullet paragraphs.** A run of one or more consecutive sibling `p` elements (outside lists and tables) whose text begins, after white space, with one of •, ◦, ▪, ▫, ‣, ⁃, ∙, ●, ○, ■, □, –, -, or * followed by a tab, becomes one `ul`, each paragraph an `li` holding its children without the leading white space, the bullet, and the tab (they may be spread over text nodes and `Apple-tab-span` spans: remove them node by node up to the first other character, and trim that text's start). The tab is required: a dialogue line such as "– Hello, she said." starts with a dash and a space, and stays a paragraph. Run the bullets before the headings, so a bullet line never becomes a heading.
9. **Pictures.** Remove every `img` and `object` element: textutil names a picture only by its attachment's file name, which the converter would read aloud.

About 150 lines with comments. No other app file changes.

## Tests

A new file `TextMouthProductionTests/TextutilHTMLStructureTests.swift`, class `TextutilHTMLStructureTests` (run `xcodegen generate`). Each test parses a small HTML string in textutil's shape (as above) with SwiftSoup, calls `restore(in:)`, and checks the result, mostly through `HTMLToMarkdownConverter.convert(document:readingFlow:)` and `MarkdownDocParser.parse(markdown:title:)` so the headings and words are those the reader will have. One helper builds a document from a style block and a body, so each test states only its rules and paragraphs.

1. Sizes and bold give headings and levels: 24 px is level 1, 18 px level 2, bold at the 12 px body level 3, and the body text stays paragraphs.
2. The chapterNumbering fixture above: Heading 1 to 4 at levels 1 to 4, Heading 5 and Heading 6 (bold at the body size) both at level 5; "Chapter numbering" stays text; the empty paragraphs add nothing.
3. The word-styles fixture: "Chapter One: The Quay" 1, "Morning Tides" 2, both 13 px paragraphs 3; the two long paragraphs and "The last paragraph is plain." stay text.
4. No larger text and no bold: no headings, and the text is unchanged.
5. Every paragraph bold: no headings from bold, while a larger paragraph in the same document is still a heading.
6. One huge decorative letter: a paragraph holding only "T" at 72 px stays text and takes no rank, so the 18 px heading after it is level 1; an inline drop cap (a 48 px span holding the first letter of a long body paragraph) stays text; a paragraph holding only "1" at 18 px is a heading.
7. Table cells and list items, bold and larger, never become headings.
8. A long bold paragraph (over 120 characters) and a long larger one stay paragraphs.
9. Seven distinct larger sizes: levels 1 to 6, the two smallest sizes both at 6.
10. A span's size wins over its paragraph's (`p.p2` at 12 px with its whole text in `span.s3 {font: 18.0px Helvetica}` is a heading), and a class rule with `font-weight: bold` counts as bold.
11. The tab-bullet-tab paragraphs (as in the first block above) become one list of three items without bullets or tabs; "– Hello, she said." stays a paragraph; a bullet run inside a table cell is left alone.
12. The picture paragraph leaves no "Attachment.png" anywhere in the Markdown.
13. Emphasis in body text survives: `<p class="p2">Smoked fish, <i>naïve</i> prices and <b>fresh</b> bread, all morning long at the quay.</p>` gives Markdown with `*naïve*` and `**fresh**`, and the parsed chapter text has no asterisk.

Run `TextutilHTMLStructureTests` and the converter's tests (`grep -l HTMLToMarkdownConverter TextMouthProductionTests/*.swift`, by class name).

## Not yours

No change to `HTMLToMarkdownConverter.swift`, `HTMLParser.swift`, or any format's wiring. Do not run textutil in a test: the fixtures above are its output.
