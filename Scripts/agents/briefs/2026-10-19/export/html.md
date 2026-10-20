# Task `html` (team export, October 19, 2026): the HTML writer

Worker `export-html`, branch `export/html` from `team/export`. FMT18. You write the first text writer: escaped XHTML from the `ExportDocument` model, which an XML parser accepts. swift-markdown's own `HTMLFormatter` inserts text unescaped and drops heading ids, which is why TextMouth writes its own. You never parse Markdown: you read the model.

## Read first (only these)
- `TextMouth/Services/Export/ExportDocument.swift` (whole, about 330 lines): the model you read.
- `TextMouth/Services/Export/TextExportWriter.swift` (whole, about 250 lines): the protocol you conform to, `TextExportError`, and `TextExportWriters.all`, where you add one line.

## Files you write
1. `TextMouth/Services/Export/XMLEscaping.swift` (new): `enum XMLEscaping` with
   - `static func text(_ text: String) -> String`: `&` as `&amp;`, `<` as `&lt;`, `>` as `&gt;`;
   - `static func attribute(_ text: String) -> String`: those, `"` as `&quot;`, and tab, line feed, and carriage return as `&#9;`, `&#10;`, `&#13;`;
   - both walk `unicodeScalars` (a Character can hold "\r\n" whole) and leave out every scalar XML 1.0 forbids: U+0000 to U+0008, U+000B, U+000C, U+000E to U+001F, U+FFFE, and U+FFFF (content.md from a PDF or a text file can hold a form feed, and one such character makes the whole page unreadable to an XML parser).
   - Its comment says it serves every writer of XML: HTML now, EPUB and braille's PEF later.
2. `TextMouth/Services/Export/HTMLExportWriter.swift` (new): `struct HTMLExportWriter: TextExportWriter` with
   - `id` "html", `name` "HTML", `fileExtension` "html", and `hint` exactly "A web page of the book's text, with a contents list linking each heading.";
   - no options (leave `Options`, `defaultOptions()`, and `optionsView(_:)` to the protocol's defaults);
   - `static func page(of document: ExportDocument, cancellation: BookExportCancellation? = nil) throws -> String`, which makes the page and calls `try cancellation?.checkCancelled()` before each top-level block;
   - `write(_:options:to:cancellation:)`, which writes `page(of:cancellation:)` as UTF-8 with `Data.write(to:options: .withoutOverwriting)`.
3. One line in `TextExportWriters.all` (`TextExportWriter.swift`): `HTMLExportWriter(),` as the array's first element. Change nothing else in that file.

## The page, exactly
Every line ends with a line feed, the last one too. Lines in square brackets are written only when their condition holds.

    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml"[ lang="LANG" xml:lang="LANG"]>
    <head>
    <meta charset="utf-8"/>
    <title>TITLE</title>
    [<meta name="author" content="AUTHOR"/>]
    </head>
    <body>
    [<h1 id="ID">TITLE HEADING'S RUNS</h1>]          when document.titleHeading is not nil
    [<nav aria-label="Contents"> ... </nav>]          when document.headings is not empty
    BLOCKS
    </body>
    </html>

- LANG is `document.book.language`, AUTHOR `document.book.author`, TITLE `document.book.title`, all escaped (`XMLEscaping.attribute` in attributes, `XMLEscaping.text` in text). There is no XML declaration.
- **The contents list** links every heading of `document.headings` (not the title heading, the page's own) by its id, with its plain text as the link's words, in nested ordered lists. `<nav aria-label="Contents">` and `</nav>` each have a line. The lists, with a stack of levels:
  - for the first heading, a line `<ol>`, and the stack holds its level;
  - for each later heading: while the stack holds more than one level and the heading's level is below the top, close the open item, add a line `</ol>`, and pop; then, when its level is above the top, add a line `<ol>` and push its level (the new list sits inside the open item); otherwise close the open item;
  - then each heading adds a line `<li><a href="#ID">TEXT</a>`;
  - at the end: close the open item; while the stack holds more than one level, add `</ol>`, close the open item, and pop; then add `</ol>`.
  - "Close the open item" appends `</li>` to the last line when that line begins with `<li>`, and adds a line `</li>` otherwise.
  - So levels 1, 3, 2 give `<ol>`, `<li>…1`, `<ol>`, `<li>…3</li>`, `</ol>`, `<ol>`, `<li>…2</li>`, `</ol>`, `</li>`, `</ol>`; and levels 2, 1 give one flat list.
- **Blocks**, each starting on a line of its own:
  - heading: `<hN id="ID">RUNS</hN>`;
  - paragraph: `<p>RUNS</p>`;
  - list: a line `<ul>`, or `<ol>`, or `<ol start="N">` when an ordered list's `start` is not 1; a line per item; a line `</ul>` or `</ol>`. An item is `<li>` followed, when its first block is a paragraph, by that paragraph's runs on the same line; each of its other blocks follows on lines of its own; the item ends with `</li>` on its last line when it has no other block, and on a line of its own when it has. An item with no blocks is `<li></li>`.
  - block quote: a line `<blockquote>`, its blocks, a line `</blockquote>`;
  - code block: `<pre><code>CODE</code></pre>`, the code escaped with its line feeds kept;
  - thematic break: `<hr/>`;
  - table: lines `<table>`; when `hasHeaderRow`, `<thead>`, the first row as `<tr><th>A</th><th>B</th></tr>`, `</thead>`; then `<tbody>`, every other row as `<tr><td>1</td><td>2</td></tr>`, `</tbody>`; then `</table>`. A row writes the cells it has. A table whose only row is its header row writes no `<tbody>`.
- **Runs:** neighbouring runs with the same `link`, when that link may be a link (check `ExportRun.isAllowedLinkAddress` again: the writer trusts no caller), are one `<a href="ADDRESS">…</a>`; any other run is written alone. A run's text is escaped, each line feed in it written as `<br/>`, and wrapped from the inside out in `<code>` (when `isCode`), `<em>` (when `isEmphasis`), and `<strong>` (when `isStrong`): `<strong><em><code>x</code></em></strong>`. There is never an `<img>`: images are already their alternative text in the model.
- Comment every function and non-obvious block. One function writes runs for every block that has them (DRY).

## Tests: `TextMouthProductionTests/HTMLExportWriterTests.swift` (new; run `/opt/homebrew/bin/xcodegen generate` and commit `project.pbxproj` with it)
A `final class HTMLExportWriterTests: XCTestCase`. The walker is being written beside you, so build every document by hand, with ids as the walker would make them. Every page a test makes goes through one helper that parses it with `XMLParser(data:)` and fails the test unless `parse()` is true with no `parserError`.
1. The exact page for a fixture with a language, an author, a title heading, headings of levels 1 to 3, a paragraph with every style and a link, an unordered list holding an ordered list starting at 3, a two-paragraph item, a quote, a code block, a thematic break, and a table with a header row: pin the whole string.
2. Escaping: `&`, `<`, and `>` in a heading, a paragraph, a code block, a cell, the title, and the author are escaped; a link to `https://example.com/?a=1&b=<2>"` is written `href="https://example.com/?a=1&amp;b=&lt;2&gt;&quot;"`.
3. Three headings reading "Notes" with ids "notes", "notes-2", "notes-3" give three `<h2>` with those ids and three contents links to them.
4. A run whose link is `javascript:alert(1)`, given by hand, is written as plain text with no `<a`; a `mailto:` link is a link.
5. The contents list for levels 1, 3, 2 and for 1, 2, 2, 1, pinned exactly; no `<nav` for a document with no headings (even with a title heading).
6. `lang` and `xml:lang` present with a language and absent without; the author `<meta>` absent without an author; `<title>` always there; the `<h1>` of the title heading only when there is one.
7. A text holding U+0001, U+000C, and U+FFFF: the page leaves them out and parses.
8. `XMLEscaping` alone: each rule above, "\r\n" in an attribute as `&#13;&#10;`, and an emoji kept whole.
9. `write`: the file holds the page's UTF-8 bytes; a second write to the same URL throws and leaves the first file as it was; a `BookExportCancellation` cancelled before the call makes `write` throw `CancellationError` and writes no file.
10. The writer's words: `id`, `name`, `hint`, and `fileExtension` exactly; `TextExportWriters.writer(id: "html")` finds it; the ids in `TextExportWriters.all` are unique and none is `TextExportWriters.markdownID`.

## Build and test
Through `python3 Scripts/test/run-area.py HTMLExportWriterTests` (read `-h` first), with your own build folder as `teams-common.md` says.

## Do not touch
`ExportDocument.swift`, `TextExportWriter.swift` beyond your one line, `BookExportService.swift`, any `BookExport*` file, the walker (`ExportDocumentWalker.swift`, another worker's), or any `*.md` file. If the model seems to need a change, stop and ask `export-lead` on the board.
