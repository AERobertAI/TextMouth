# The HTML parser's size and the import's algorithms: research (November 14, 2026)

Written by the research agent `parseresearch` on November 14, 2026, from main at a1214dc0b (version 0.4.10). Nothing in the app was changed: every measurement was made in scratch copies under `build/orchestrator/nov14/parseresearch/`. A megabyte here is 1,000,000 bytes, as `Scripts/check.sh` counts the app's size.

## Summary

**Can the HTML parser get smaller? Yes, by about a third, and it gets faster too.**

- It is 1.13 MB today, not 3 MB: 0.4.8 already took it from 2.98 MB to 1,132,786 bytes, 6.5% of the executable.
- A copy of SwiftSoup with only its attributes changed (forced inlining removed, what the app never calls made internal, no parsing code touched) is 0.73 MB in a real Release build: the app is **407,000 bytes smaller** (18.3 MB to 17.9 MB), and parsing is **37% faster**, so EPUB and HTML imports are about 10% faster.
- It builds the same trees: 41,100 parses of the test files and of damaged copies of them gave identical results in eight builds.
- It cannot go much lower without changing what books say. No other parser builds the same trees: a parser that follows the HTML standard reads 21 of the 92 test documents differently, every chapter of the test EPUB among them.

**Are there better algorithms for import? Not a better kind; the kind is already right. There are cheaper steps.**

- Every format's import already grows in step with the book: at 4 and 16 times the size, in 6 formats and 7 awkward shapes, nothing took more than its share. A novel imports in 0.03 to 0.2 seconds.
- Profiling found steps that cost more than they should. Small, safe changes would take about 45% off an RTF import, 25% off DOCX, 30% off plain text, and 18% off EPUB.
- One larger change, reading Markdown through cmark directly instead of through swift-markdown, would take 12% to 30% more off every text import and 0.46 MB off the app. It needs the user's yes.
- PDFs are the only imports that take seconds, and 92% to 95% of that is inside Apple's PDFKit.

## Part 1: can the HTML parser get smaller?

### 1.1 What the parser weighs today

I built Release from main with the Makefile's own settings, unsigned, with a link map (`release/TextMouth.map` in the scratch folder).

- The executable is 17,649,736 bytes. Its symbols add up to 17,412,736 bytes.
- SwiftSoup 2.13.9 is 1,132,786 of them, in 15,205 symbols: 6.5% of the executable. The audit's figure was 1,132,770, so it holds.
- So "the 3 MB parser" has been a 1.13 MB parser since 0.4.8, when the packages began to be compiled for size.

Its largest parts, in bytes:

- Helpers the compiler shares between types, and outlined code: 202,306
- `Element`: 143,163
- `CharacterReader`: 47,984
- `Token`: 43,744
- `HtmlTreeBuilderState`: 41,040 (one function, `process`, is 36,124)
- Literal strings: 41,027 (the table of entity names is 31,800)
- `Entities`: 38,785
- The selector engine (`Evaluator`, `CssSelector`, `QueryParser`, `Elements`, `StructuralEvaluator`, `Collector`): about 111,000
- `Node`: 35,096
- `Attributes`: 34,659
- `HtmlTreeBuilder`: 33,452
- The cleaner (`Whitelist`, `Cleaner`, and their value types), which TextMouth never calls: about 34,000

### 1.2 What TextMouth calls

21 source files import SwiftSoup. All parsing goes through `MarkupGuard`. Read by eye from every call site, the app uses about 45 methods of 12 types:

- Parsing: `SwiftSoup.parseHTML(_:_:)`, `SwiftSoup.parse(_:_:_:)` with `Parser.xmlParser()`, and `SwiftSoup.parseBodyFragment(_:)`.
- `Document`: `body()`, `title()`.
- `Node`: `getChildNodes()`, `parent()`, `previousSibling()`, `remove()`, `after(_:)`, `hasAttr(_:)`, `attr(_:)`, `attr(_:_:)`, `absUrl(_:)`, `outerHtml()`, `getAttributes()`, `copy()`.
- `Element`: `tagName()`, `tagName(_:)`, `tag()`, `id()`, `text()`, `html()`, `data()`, `isBlock()`, `classNames()`, `children()`, `select(_:)`, `getElementById(_:)`, `prependChild(_:)`, `addChildren(_:)`, and `Element(_:_:)`.
- `TextNode`: `getWholeText()`, `text(_:)`, `isBlank()`, and `TextNode(_:_:)`.
- `Comment.getData()`; `XmlDeclaration.name()` and `getWholeDeclaration()`.
- `Attributes.asList()`; `Attribute.getKey()` and `getValue()`.
- `Elements`: `array()`, `first()`, `isEmpty()`, `remove()`.
- `Tag.valueOf(_:)` and `preserveWhitespace()`; `Entities.unescape(_:)`; and `OrderedSet<String>`, which `classNames()` returns.

`select` is called 7 times, with 6 simple selectors (`meta`, `meta[name=author]`, `p`, `style`, `img, object`, and `[role=…]`). The cleaner, forms, and output settings are never named by the app.

The tests call a little more. 20 test files import SwiftSoup, and they also use `size()`, `last()`, `eachText()`, `ownText()`, `getAllElements()`, `outputSettings().prettyPrint(pretty:)`, `StringUtil.normaliseWhitespace`, and selectors such as `body > ul > li`. So the selector engine has to stay while those tests do.

### 1.3 Why it is larger than it needs to be

Three things in SwiftSoup's own source, none of them in its parsing logic:

1. **Forced inlining.** The source holds 802 `@inline(__always)` attributes. Each one orders the compiler to copy a helper into every caller. Compiled as a whole module, that is what made SwiftSoup 3 MB.
2. **Everything is public.** 1,408 declarations are `public` or `open`, and nearly every class can be subclassed. The compiler must keep every method of a class once the class is used, because code outside might call or override it. That is why the cleaner and methods TextMouth never calls are still in the app.
3. **Today's cure has a cost.** Since 0.4.8 the package is compiled file by file at `-Osize`, which stops the copying, because one file cannot see into another. But it also stops every optimization that crosses a file, which is why parsing became slower.

A copy of SwiftSoup with those attributes changed, and nothing else, removes all three.

### 1.4 What I built and measured

`tools/soup_transform.py` writes a changed copy of SwiftSoup's 60 Swift source files (34,687 lines). It changes only attributes:

- it removes every `@inline(__always)`, `@inlinable`, and `@usableFromInline`;
- it makes every `public` or `open` declaration internal unless its name is one TextMouth calls (`tools/allow-api.txt`, 76 names), which leaves 343 public declarations of 1,408;
- it marks `final` the 37 classes that nothing inherits from and that were not final already (98 of the classes are then final);
- it leaves out `Cleaner.swift` and `Whitelist.swift`, and the four functions of `SwiftSoup.swift` that use them.

No line of the tokeniser, the tree builders, the entity table, or the serialiser changes. The compiler checks the result; `tools/soup_check.py` follows the compiler's own access errors to correct 11 lines.

Each variant was compiled with the flags Xcode gives the package, linked with dead stripping into a harness that calls SwiftSoup through the app's API (`soup/driver/main.swift`), and timed: the median of 31 parses of `TestData/frankenstein.html` (468,174 bytes, by the HTML parser) and of 21 parses of the DTBook XML inside `TestData/hyperion_daisy.zip` (1,440,244 bytes, by the XML parser, which most EPUB chapters go through). The harness's first row is within 1.1% of the real app (1,144,774 against 1,132,786), so it is a fair stand-in.

| Build of SwiftSoup | Bytes kept | HTML parse | XML parse |
| --- | --- | --- | --- |
| Shipped: 2.13.9, `-Osize`, file by file | 1,144,774 | 5.8 ms | 26.3 ms |
| Before 0.4.8: 2.13.9, `-O`, whole module | 2,988,225 | 3.4 ms | 15.5 ms |
| Trimmed copy, `-Osize`, whole module | 714,031 | 3.6 ms | 16.3 ms |
| Trimmed copy, `-Osize`, hot functions for speed | 780,471 | 3.1 ms | 15.3 ms |
| Trimmed copy, `-O`, whole module | 973,787 | 3.0 ms | 12.8 ms |
| Trimmed copy, selectors unreachable, `-Osize` | 628,898 | 3.4 ms | 16.4 ms |

The other variants, for the record:

- 2.13.9, `-O`, file by file: 1,405,194 bytes; 5.0 ms and 23.4 ms.
- 2.13.9, `-Osize`, whole module: 2,062,455 bytes; 3.9 ms and 18.2 ms.
- 2.13.9 with only the forced inlining removed, `-Osize`, file by file: 999,832 bytes; 5.9 ms and 26.5 ms.
- 2.13.9 with only the forced inlining removed, `-Osize`, whole module: 960,629 bytes; 4.3 ms and 19.8 ms.
- The trimmed copy, `-Osize`, file by file: 807,035 bytes; 5.7 ms and 25.9 ms.
- The trimmed copy with selectors unreachable, `-O`, whole module: 846,292 bytes; 3.0 ms and 12.6 ms.

What the numbers say:

- **The trimmed copy is 38% smaller than what ships and parses 37% faster.** Size and speed stop being a trade: the forced inlining was costing both.
- Removing the forced inlining alone, compiled whole, gives 960,629 bytes: 16% smaller with no access change at all.
- "Selectors unreachable" is what the app would link if its 7 `select` calls became tree walks. It saves 85,000 bytes more, but the tests use selectors, so I do not propose it now.
- The harness's name list is coarse (a name such as `text` is kept public on every type). A hand-kept list of about 50 declarations would trim perhaps 30,000 to 50,000 bytes more. That is a guess; everything else here is measured.

### 1.5 The same trees: how I checked

A copy that changes only attributes must build identical trees. I checked that it does, rather than assume it.

- `tools/make_corpus.py` gathered every markup document in `TestData`: 660 documents, 8,006,855 bytes (the members of every EPUB, DAISY ZIP, DOCX, and ODT, the format samples, and the loose HTML and XML files).
- The harness's corpus mode parses each document three ways, as the app does (the HTML parser, the XML parser, and a body fragment), then 20 damaged copies of each document of up to 300,000 bytes. A damaged copy has a range deleted, a range repeated, or a piece of troublesome markup inserted (unclosed formatting, table parts, `<select>`, `<svg>`, broken character references, half comments), three times a copy, with a fixed seed.
- For each parse it prints one checksum over the whole tree as the converter walks it (every element's name, every attribute, every text node), the document's `text()`, its `outerHtml()`, and its `title()`.
- That is 13,700 inputs and 41,100 parses. Eight builds were compared: the one before 0.4.8, the shipped one, and six changed copies, among them the one I recommend vendoring and the one with its hot functions marked for speed. **Every one of the 41,100 results is identical in all eight builds.**

One thing the harness had to step around: SwiftSoup 2.13.9's XML builder traps on a declaration that names no element (`<?>` for one; `XmlTreeBuilder.swift:121`). TextMouth is already safe from it, because `MarkupGuard.parseXML` replaces such declarations first. I mention it only because a raw fuzz of SwiftSoup finds it within nine documents.

What this does not replace: when the copy is built for real, the golden tests must pass with it. They are `TextPipelineGoldenTests`, `DocumentGoldenTests` (the 57 files of `TestData/golden`), `MarkupGuardTests`, `PortableXMLDifferentialTests`, and `ParserContentFidelityTests`, plus the `import`, `readers`, and `feeds` areas of `Scripts/test/areas.conf`, and `Scripts/test/release-goldens.sh` once, since the change is to a Release build. I did not run them: a Debug test build needs about 3 GB, and the disk stood at 9.1 GB free.

### 1.6 In the real app

I put the trimmed copy into a scratch clone of the repository as a static library target of the project (`Vendor/SwiftSoup`, compiled whole-module), pointed the Mac app at it in place of the package, and built Release the same way.

| Release build | Executable | SwiftSoup in it |
| --- | --- | --- |
| main, 0.4.10 | 17,649,736 | 1,132,786 |
| Trimmed copy, `-Osize` | 17,242,664 | 726,773 |
| Trimmed copy, `-O` | 17,455,336 | 942,286 |

- At `-Osize` the app is **407,072 bytes smaller** (2.3%): 18.3 MB becomes 17.9 MB.
- At `-O` for this one target the app is still 194,400 bytes smaller than today, and the parser is faster than it was before 0.4.8.
- A copy that also keeps public what the tests call (section 1.2) is 730,093 bytes in the app, 3,320 more, and the executable 17,242,696. So the tests' needs cost nothing to speak of, and this is the copy to vendor.

Import times, measured with the app's own code (Part 2 describes the benchmark), shipped parser against trimmed copy at `-Osize`, two rounds each, best of the medians:

- EPUB: 89.4 ms to 80.8 ms for the novel (10% faster); `alice.epub` 31.9 to 28.7 ms (10%).
- HTML: 68.3 to 62.1 ms (9%). KF8: 22.2 to 19.7 ms (11%). RTF: 193.4 to 185.6 ms (4%).
- DOCX, plain text, Markdown, and DAISY: unchanged, within 3%.

### 1.7 Speed at little size cost

The brief asked whether `-O` on the tokeniser's hot files alone would give the speed back. It does not:

- `-O` for `Tokeniser.swift`, `TokeniserState.swift`, `CharacterReader.swift`, and `Token.swift`, the rest at `-Osize`, file by file: 61,057 bytes larger, and the parse goes from 5.8 to 5.5 ms (6%).
- `-O` for eight files (those and the tree builder's and `Attributes.swift`): 111,942 bytes larger, 5.2 ms (11%).

The slowness of the shipped build is not the optimization level. It is that a file-by-file build cannot inline or specialize across files, and the tokeniser, its reader, and its tokens are in different files. Only a whole-module build gives that back, and a whole-module build is only small once the forced inlining is gone. So the answer to "speed at little size" is the trimmed copy itself. Its three settings, from the table above:

- `-Osize`: smallest (714,031), 37% faster than today.
- `-Osize` with `@_optimize(speed)` on the functions of the tokeniser and the tree builder: 66,440 bytes more, 46% faster than today, and faster than before 0.4.8. The attribute is one the Swift compiler supports but marks with an underscore, so it could change in a later Swift.
- `-O`: 259,756 bytes more than the smallest, 48% faster.

I recommend plain `-Osize`: the parser is about a tenth of an EPUB's import after the change (Part 2), so the last 10% of parser speed is about 1% of an import.

### 1.8 Other parsers

The question was whether another parser could give the exact same tree for the same input in less space.

**A parser that follows the HTML standard (lexbor, Gumbo, html5ever, or one written by hand).** They build the standard's tree, and SwiftSoup's tree is not always the standard's. To count how often, I used the one standard-following parser already on every Mac, WebKit (`alt/wkdump.swift`: page scripts off, every load blocked, no window), and compared its tree with SwiftSoup's HTML parser's for the 92 HTML and XHTML documents of the test files, and for 460 damaged copies of them.

- Documents as they are: 64 of 92 the same tree; 7 the same words and elements with different white space or comments; **21 read differently**.
- Damaged copies: 235 of 460 the same tree; 49 the same reading; **176 read differently**.

All 21 have one cause: an empty element written XML's way, such as `<a id="chap01"/>`, `<div/>`, or `<span epub:type="pagebreak"/>`. SwiftSoup closes it there. The HTML standard ignores the slash, so the element stays open and swallows what follows: a chapter's title ends up inside an anchor, a paragraph inside a page break. The 21 are every chapter of `TestData/alice.epub` (Project Gutenberg's own EPUB) and every page-break sample. So a standard-following HTML parser would change the reading of ordinary EPUBs, not only of broken ones.

That could be stepped around by reading XHTML with an XML parser instead. But real EPUBs are often not well-formed, and today the lenient reader of malformed XML is SwiftSoup's own XML builder. So a replacement means two new parsers (HTML and lenient XML), each to be matched to SwiftSoup's behavior, and `MarkupNesting` (1,652 lines, a rule-by-rule map of SwiftSoup's tree builder "with its slips") rewritten for them.

- lexbor: Apache License 2.0, C, maintained (version 3.1.0, last changed on November 11, 2026). Its HTML parser needs its `core`, `dom`, `tag`, `ns`, and `html` modules: 37,958 lines of C, without the encoding tables.
- Gumbo: Apache License 2.0, C, 31,185 lines with its generated tables (Google's repository, last changed on January 21, 2026).
- I downloaded both and wrote a tree dumper for each (`alt/lexdump.c`, `alt/gumbodump.c`), but **I did not build or run them**: the session's permission check refused to run code compiled from downloaded sources, and I did not work around it. So I have no measured size for either. From their line counts I would guess 250,000 to 400,000 bytes for Gumbo and 400,000 to 700,000 for lexbor. Both are designed to give the standard's tree, which is the tree WebKit gives, so the counts above stand for them.
- A hand-written parser that kept SwiftSoup's exact trees would be SwiftSoup written again: its tokeniser, both tree builders, its slips, and its entity table. I would expect 300,000 to 450,000 bytes of Swift, for months of work and a new parser to prove on every book.

**macOS's libxml2** (the audit's rejected option). `tools/xmllint_dump.py` ran the system's `xmllint --html` on the same 552 files. Of the 92 documents as they are, none has the same tree, 82 read the same, 3 read differently, and 7 came out as XML I could not read back. Of the 460 damaged copies, 215 read differently. The audit was right to advise against it.

**Conclusion.** No other parser gives the same trees. The trimmed copy does, by construction and by 41,100 checked parses, and it is 0.73 MB in the app. A different parser might reach 0.3 to 0.5 MB (a guess), so the most it could save beyond the trimmed copy is about 0.3 MB, for the price of changing what some books say.

### 1.9 What the change would be

- `Vendor/SwiftSoup/`: SwiftSoup 2.13.9's sources as the script writes them, with its MIT licence, and the script and name list beside them (`Scripts/…`), so an upgrade is "run the script on the new release, then the corpus check", not a hand merge.
- `project.yml`: a static library target for it for each platform, as LAME has (`LAME` and `LAME_iOS`), with `SWIFT_COMPILATION_MODE: wholemodule`, in place of the package. The Makefile's `SWIFT_OPTIMIZATION_LEVEL=-Osize` reaches it as it reaches every target. (Should `-O` ever be wanted for this one target, the level on the command line overrides a target's own, so it goes in the target's `OTHER_SWIFT_FLAGS`, which come later on the compiler's command line; that is how the `-O` row of section 1.6 was built.)
- The corpus comparison kept as a tool (`Scripts/test/`), run when SwiftSoup's version or the script changes.
- The name list must keep what the tests call (section 1.2).
- Things for the builder to check that I did not: the hosted tests link SwiftSoup's symbols through the app (`BUNDLE_LOADER`), and a static library gives the app only the objects it uses, so a symbol only a test calls may need the library force-loaded in Debug; the iPhone target; and `make check`'s warning gate (the target needs `SWIFT_SUPPRESS_WARNINGS`, as packages have).
- Cost to keep: SwiftSoup is already pinned to 2.13.9 exactly, and `MarkupNesting` already ties TextMouth to that version's behavior, so upgrades are deliberate today too.

## Part 2: better algorithms for import

### 2.1 How I measured

- **The benchmark is the app's own code.** `tools/appbench_build.py` compiles 754 of the 755 Swift files of the Mac app's Release build (all but its entry point) with one small file of mine (`bench/main.swift`), at the shipped settings (`-Osize`, whole module), and links the packages the Release build made. So the times are the shipped code's.
- **It cannot reach the library.** It runs with the hosted-test switch on, so `TextMouthRuntime` gives it a sandbox home in the temporary directory, as the hosted tests have. It refuses to start otherwise, and it runs under `sandbox-exec` with a profile that denies `~/.TextMouth` and the cloud folders outright. It opens no window and plays nothing.
- **An import here is the whole of `FileImportService.importFileWithReport`**: checksum, metadata, staging, copy, reading the text, writing and reading back the record, and the rename. Each time is the median of 5 imports (3 for the larger files).
- **The books are generated, or the repository's own.** `tools/make_bench_inputs.py` makes a novel from `TestData/pride.txt` (61 chapters, 2,361 paragraphs, 0.72 MB of text) as EPUB 3, HTML, plain text, Markdown, DOCX, and RTF, once, four times over, and sixteen times over. `tools/make_shape_inputs.py` makes seven awkward shapes in two sizes each. None of the user's books was read.
- **Profiles** are from macOS's `sample`, 6 seconds at one sample a millisecond, while the benchmark repeats the import's reading step on one package (`logs/profile-*.txt`).

### 2.2 What an import spends its time on, step by step

For the novel as an EPUB, 89.8 ms in all:

- Before the copy (the source's checksum, its metadata, the staged package): 4.0 ms.
- The copy: 0.2 ms. It is a clone on APFS, so it does not grow with the book.
- Reading the text (`readingText`): 84.1 ms.
- Writing the record and reading it back: 1.4 ms.
- The rename that publishes the package: 0.1 ms.

That holds for every format: reading the text is 93% to 99% of an import. Copying and the record are not worth touching. Nor is hashing: the source is digested twice (for the checksum, then for the cache's fingerprint) and content.md once, which together are under 2% of an EPUB import and about 6% of a Markdown one, the fastest import there is.

### 2.3 How long an import takes

The novel, 0.72 MB of text, by format:

| Format | Import | First open | Peak memory |
| --- | --- | --- | --- |
| Markdown | 31 ms | 17 ms | 31 MB |
| Plain text | 50 ms | 16 ms | 37 MB |
| HTML | 69 ms | 18 ms | 42 MB |
| EPUB | 90 ms | 22 ms | 52 MB |
| DOCX | 153 ms | 18 ms | 43 MB |
| RTF | 195 ms | 18 ms | 47 MB |

The repository's test books:

- `alice.epub`: 32 ms. `alice.docx`: 63 ms. `frankenstein.html`: 35 ms. `pride.txt`: 72 ms.
- DAISY: `hyperion_daisy.zip` (1.0 MB of text) 78 ms; `lathe_of_heaven_daisy.zip` 31 ms.
- Kindle: a KF8 file 11 ms; an AZW3 21 ms; a KFX 35 ms.
- Braille: `wrapped-titles.brf` 35 ms, of which 60% is waiting for the braille helper (liblouis).
- Word 97-2003: `poi-rasp.doc` 4.5 ms.
- PDF: `relativity-einstein.pdf` (154 pages) 716 ms; `ebook-history.pdf` (95 pages) 982 ms; `portland-accessibility.pdf` (pictures to recognize) 2,786 ms and 243 MB; `scanned-github.pdf` (8 scanned pages) 5,380 ms and 287 MB.

So a text book imports in between a thirtieth and a fifth of a second, and PDFs are the only imports that take seconds.

### 2.4 Does anything grow faster than the book?

This is the question "is there a better algorithm" comes down to: a step that is quadratic shows as a time that more than quadruples when the book quadruples. Nothing does.

The novel four times over, against once (a ratio of 4.0 is exactly linear):

- EPUB 3.94; HTML 3.81; plain text 3.70; Markdown 3.83; DOCX 3.92; RTF 3.96.

Sixteen times over (11.5 MB of text; 16.0 is linear):

- EPUB 15.4 (1.38 s); HTML 16.0 (1.10 s); plain text 16.1 (0.80 s); DOCX 15.8 (2.42 s).

The awkward shapes, each at a size and at four times it:

- 1,000 and 4,000 tiny chapters in one EPUB: 384 ms and 1,400 ms (3.64).
- One EPUB document with 2,500 and 10,000 headings, each a contents entry with a page break after it: 262 ms and 1,014 ms (3.87).
- HTML with 20,000 and 80,000 emphasised words and as many links in 20 long paragraphs: 604 ms and 2,364 ms (3.91).
- An HTML table of 5,000 and 20,000 rows: 143 ms and 539 ms (3.76).
- Plain text of 50,000 and 200,000 short paragraphs: 266 ms and 1,031 ms (3.88).
- Plain text that is one line of 100,000 and 400,000 words: 30 ms and 96 ms (3.21).
- Markdown of 20,000 and 80,000 list items, a third nested: 131 ms and 507 ms (3.87).

October's performance review (PERF18 to PERF25) removed the quadratic steps, and none has come back. What is left is constant factors: how much each byte, element, or line costs.

Memory also grows in step with the book: about 25 bytes at peak for each byte of text in a single-document format (289 MB for 11.5 MB of plain text), and 463 MB for the 4.9 MB HTML file of 160,000 inline elements.

### 2.5 Where the time goes

For the novel as an EPUB, as shares of the reading step:

- Building the tree from each chapter's XHTML (SwiftSoup): 16%.
- Turning the tree into Markdown: 22%. Of that, asking each element whether it carries an EPUB type: 5%.
- Reading that Markdown back for the reading text, headings, and pages: 22%. Of that, the C parser (cmark) is under 4%; swift-markdown's Swift tree built on top of it is 9%; the walk over that tree is 7%.
- Removing page markers with a regular expression, to see whether a chapter is blank: 7%.
- Reading the package document, the NCX, and the page list by XPath: 6%.
- Word counts and the content index: 4%.
- Unzipping: 3%. Digests, the write of content.md, and the rename: 3%.
- Starting a big-stack thread for each parse, and everything else: about 17%.

No one step dominates an EPUB. The other formats each have one or two that do, listed next.

### 2.6 The hot spots, and what would be better

Each entry says what the code does now, what would do the same work for less, the gain, and what proves the output is unchanged. The gains are shares of that format's import from the profiles, unless I say I measured the replacement.

**H1. RTF: counting characters to find headings by size (49% of an RTF import).**
- Now: `RTFSizeHeadings.swift:43` counts each run's characters that are not white space by walking it as Swift `Character`s and asking each `isWhitespace`. `RTFSizeHeadings.swift:116` then splits every paragraph's whole text at white space, joins it, and counts it, only to learn whether it is at most 120 characters long. Both look up Unicode properties for every character of the book.
- Better: stop the length test at the 121st character, since no longer paragraph can be a heading; and count plain ASCII bytes directly, keeping today's walk for any run that holds other characters. `Chapter.wordCount` already does the second (PERF21).
- Gain: about 45% of an RTF import (the novel: 195 ms to about 105 ms).
- Unchanged output, proved by `RTFReaderTests`, `RTFTextutilComparisonTests`, `RTFTableListTests`, and the RTF files of `DocumentGoldenTests`.

**H2. DOCX: splitting every run at line feeds, and stripping a prefix (25%).**
- Now: `DOCXParser+Converter.swift:1160` splits each run's text at "\n" as `Character`s, though a run almost never holds one: 19% of the import. `ParserUtilities.swift:28` strips an element name's prefix with `components(separatedBy: ":")` for every start and end tag, which builds an array of strings each time: 6%.
- Better: look for the byte 0x0A first and skip the split when it is absent (a run without that byte has no line-feed character, so the result is the same one line); and take the name after the last ":" byte.
- Gain: about 25% of a DOCX import (153 ms to about 115 ms). The prefix helper also serves DTBook and DAISY.
- Proved by the ten `DOCX…Tests` classes, `DTBookImportTests`, and `DocumentGoldenTests`.

**H3. Plain text, Markdown, HTML: two searches for one byte (7% to 17%).**
- Now: `TextEncodingGuesser.swift:155` asks `data.contains(0x1B)` and `TextFileDecoder.swift:991` asks `text.utf8.contains(0x0D)`. Both walk the file a byte at a time through Swift's generic iterator: 6% to 9% of a Markdown or plain-text import for the first, 8% to 10% for the second.
- Better: `memchr` over the contiguous bytes, which the C library runs with vector instructions.
- Gain: about 15% of a plain-text or Markdown import, 7% of an HTML one.
- Proved by `TextEncodingGuesserTests`, `TextFileDecoderTests`, `TextEncodingFidelityTests`, and the goldens. The answer to "is this byte present" cannot differ.

**H4. Plain text: splitting into lines with Foundation (20%).**
- Now: `PlainTextParser.swift:202` splits the text with `components(separatedBy: .newlines)` and trims each line with a `CharacterSet`: 16% and 6% of a plain-text import.
- Better: one pass over the UTF-8 bytes that cuts at the same seven characters `.newlines` holds (U+000A to U+000D, U+0085, U+2028, U+2029), trimming ASCII spaces and tabs in the same pass and leaving any line with another character at its edge to today's trim.
- Gain: about 18% of a plain-text import. With H3, the novel goes from 50 ms to about 34 ms.
- Proved by `PlainTextFormFeedPageTests`, `TextPipelineGoldenTests`, and the plain-text goldens. This one needs the most care of the safe ones: the seven characters and the trim must match exactly.

**H5. EPUB: a regular expression to learn whether a chapter is blank (7%).**
- Now: `EPUBParser+Navigation.swift:359` removes every page marker from the chapter's whole Markdown with a regular expression (`:575`), trims the result, and asks only whether it is empty.
- Better: scan from the start, skipping white space and page markers, and stop at the first other character. For any chapter with text that is its first few bytes.
- Gain: 7% of an EPUB import. Proved by `EPUBPageListTests`, `EPUBStructureFailureTests`, `EPUBPartialExtractionTests`, and `TextPipelineGoldenTests`.

**H6. EPUB and Kindle: asking each element for its EPUB type by listing its attributes (3% to 16%).**
- Now: `PublicationSemantics.swift:26` takes each element's whole attribute list (`asList()`) to look for a name ending ":type". In a book with page breaks every element is asked.
- Better: find the names ending ":type" that the document's source holds, once (nearly always just `epub:type`), and ask each element for those by name.
- Measured in the SwiftSoup harness on the 2,500-heading document: asking all 7,500 elements costs 62.2 ms by list and 24.5 ms by name, with the same 2,500 page breaks found.
- Gain: 3% of the novel's import; 16% of a book dense with headings and pages. Proved by `EPUBPageListTests`, `EPUBHeadingRecoveryTests`, `KF8BookTests`, and the goldens.

**H7. EPUB: XPath for the package document, the NCX, and the page list (5% to over 20%).**
- Now: 21 `nodes(forXPath:)` calls in the EPUB reader, most of the form `//*[local-name()='item']`, run by Foundation's XQuery engine. And the package document is read twice in an import, once for the metadata and once for the text.
- Better: one walk of the parsed document's elements that fills the manifest, spine, and metadata; and hand the metadata reader's result to the text reader.
- Gain: about 5% of the novel's import; over 20% of the 1,000-chapter book's. Proved by `EPUBMetadataTests`, `EPUBAuthorNameTests`, `EPUBHeadingRecoveryTests`, `EPUBLinkAddressTests`, and the goldens.

**H8. EPUB: the archive is opened twice, and its entries walked for the metadata (up to 3%; up to 15% for a thousand files).**
- Now: `EPUBParser.readMetadata` (`EPUBParser.swift:137`) opens the ZIP without the index PERF20 gave the text reader, so finding `container.xml` and the package document walks the central directory, and the text reader then opens the archive again. The time before the copy grows with the archive's entries: 4 ms for the novel's 64, 13 ms for 247, 57 ms for 1,003 (of a 384 ms import). Part of that is H7's second read of the package document.
- Better: use `IndexedArchive` there too, or open the archive once for the import.
- Gain: at most 3% for a novel, at most 15% for a book of a thousand files, shared with H7. Proved by `EPUBMetadataTests` and the import tests.

**H9. Every text format: reading Markdown back through swift-markdown (12% to 30%, and most of a first open).**
- Now: `MarkdownParser.swift` parses each chapter with `Document(parsing:)`. cmark, the C parser inside, takes 3% to 6% of an import. swift-markdown then builds a Swift tree from cmark's tree (8% of an EPUB import, 21% of a Markdown one, 53% of a list-heavy one), and `PlainTextExtractor` walks that (7% to 23%).
- Better: walk cmark's own tree (`cmark_iter`), which is already in memory, and build nothing on top of it.
- Gain: about 12% of an EPUB import, 14% of plain text, and 30% of Markdown. A book's first open should gain the most, since it is mostly this step, but I did not profile the open. If the exporter's walker (`ExportDocumentWalker.swift`) is moved the same way, swift-markdown leaves the app: 456,370 bytes.
- Risk: medium. The two walkers must make exactly the text, headings, and pages swift-markdown's tree gives, including its handling of tables, HTML comments (the page and heading markers), and soft breaks. The reading-text digests of `TextPipelineGoldenTests` and the 57 goldens would catch a difference, but this is a rewrite of the step every book passes through. **It needs the user's yes.**

**H10. DAISY and DTBook: appending the XML parser's strings one scalar at a time (10%).**
- Now: `DAISYParser+TextExtraction.swift:281` appends each `foundCharacters` string, which arrives as a bridged `NSString`, to a Swift string. For text that is not ASCII Swift converts it a scalar at a time (`_foreignAppendInPlace`: 10% of the `hyperion` import).
- Better: make the string native UTF-8 in one step first (`makeContiguousUTF8()`), then append.
- Gain: up to 10% of a DAISY text import. Proved by `DTBookImportTests`, `DAISYPageTests`, and the DAISY goldens.

**H11. PDF: Apple's PDFKit is 92% to 95% of the time.**
- Now: for each page the reader asks PDFKit for `string` and `attributedString` (`PDFTextParser.swift:291, 294`). Building the attributed string is 65% to 68% of the import, half of it creating a font for every run of text; the page's layout, which both calls use, is another 22% to 29%.
- I checked whether the two calls do the layout twice. They do not: `string` then `attributedString` costs the same as `attributedString` alone (660 ms and 658 ms for the 154 pages), so there is nothing to save by dropping one. The text of the two is equal on all 306 pages of the test PDFs.
- What does help: two `PDFDocument`s opened from the same file, each reading every other page on its own thread, read the 154 pages in 376 ms instead of 659 ms, and the 95 pages in 525 ms instead of 931 ms, with the same text on every page. Four are slower than two (598 ms): they wait on each other inside PDFKit.
- Gain: about 40% of a PDF import. Risk: Apple does not promise PDFKit works from two threads, even with a document each, and the pages' recognition (OCR) must stay in order. **It needs the user's yes.**

**H12. Small ones.**
- A big-stack thread is started and joined for each parse (`MarkupGuard.onLargeStack`): 1% to 2% of a novel, 6% of the 1,000-chapter book. One thread kept for the length of an import would do.
- An EPUB with 4,000 tiny chapters peaks at 200 MB, against 67 MB for 1,000: about 44 KB held for each chapter until the book ends. The likely cause is that the chapters are read with no autorelease pool around each (the PDF reader drains one for each page); I did not confirm it.
- The staged copy is a clone of the file whose checksum was just taken, yet it is digested again for the cache's fingerprint: one pass over the source could be saved for a plain file (2% of a Markdown import).
- `Chapter.wordCount` (3% to 9%) walks `String.UTF8View` by index; over the raw bytes it would be several times faster.
- All of these leave the output as it is.

**What I looked at and would leave alone.**
- The checksum (MD5 through CryptoKit) and the copy: together under 2%.
- The record (`bookInfo.json` written and read back): 1.4 ms for a novel; 10 ms for a thousand chapters.
- The braille reader: its time is liblouis in the helper.
- Recognizing scanned pages: Apple's Vision, 0.5 to 0.7 s a page.
- The re-read queue's limit of two books at once (`TextCacheUpdateQueue.swift:52`). An import peaks at 30 to 300 MB, so four at once would fit in 8 GB, and a library-wide re-read would take about half the time. But 640 novel-sized books are about a minute of processor time in all, so it is half a minute saved once per cache change, against the caution that limit was set for.

## Part 3: the proposals, ranked

Each proposal is marked **Safe** (the output is unchanged, and the named tests prove it) or **Needs the user's yes** (it vendors a dependency, or the output could change). Sizes are bytes of the executable; speeds are shares of that format's import.

### For size

1. **Vendor the trimmed SwiftSoup** (Part 1). 407,040 bytes smaller with the tests' names kept public, measured in a real build; parsing 37% faster; EPUB, HTML, and KF8 imports 9% to 11% faster. **Needs the user's yes**, because it puts a dependency's source in the repository; the output is unchanged, by 41,100 identical parses, and `TextPipelineGoldenTests`, `DocumentGoldenTests`, `MarkupGuardTests`, `PortableXMLDifferentialTests`, `ParserContentFidelityTests`, and `Scripts/test/release-goldens.sh` must pass with it before it merges.
2. **Read Markdown from cmark's own tree** (H9). 456,370 bytes smaller once the exporter's walker follows; 12% to 30% off every text import. **Needs the user's yes**: the output could change if the new walk differs anywhere, and the goldens are the gate.

### For speed, safe

3. **RTF: the heading census** (H1). About 45% off an RTF import. Safe: `RTFReaderTests`, `RTFTextutilComparisonTests`, `RTFTableListTests`, `DocumentGoldenTests`.
4. **DOCX: the run split and the prefix helper** (H2). About 25% off a DOCX import. Safe: the ten `DOCX…Tests` classes, `DTBookImportTests`, `DocumentGoldenTests`.
5. **Two byte searches by `memchr`** (H3). About 15% off plain text and Markdown, 7% off HTML. Safe: `TextEncodingGuesserTests`, `TextFileDecoderTests`, `TextEncodingFidelityTests`.
6. **EPUB: four small steps** (H5, H6, H7, H8): the blank-chapter test without a regular expression, EPUB types asked by name, the package document walked once instead of queried by XPath, and the archive indexed for the metadata. About 18% off a novel's import together, more for books with many files, headings, or pages. Safe: `EPUBPageListTests`, `EPUBHeadingRecoveryTests`, `EPUBStructureFailureTests`, `EPUBPartialExtractionTests`, `EPUBMetadataTests`, `EPUBAuthorNameTests`, `EPUBLinkAddressTests`, `KF8BookTests`, `TextPipelineGoldenTests`.
7. **Plain text: lines split by bytes** (H4). About 18% off a plain-text import. Safe, with the most care of these: `PlainTextFormFeedPageTests`, `TextPipelineGoldenTests`, and the plain-text goldens.
8. **DAISY text appended as native strings** (H10), and the small ones (H12). Up to 10% off a DAISY import; lower peak memory for books of thousands of chapters. Safe: `DTBookImportTests`, `DAISYPageTests`, and the goldens.

### For speed, needing a decision

9. **PDF pages read by two workers** (H11). About 40% off a PDF import, measured on the test PDFs with the same text on every page. **Needs the user's yes**: Apple makes no promise that PDFKit may be used from two threads.

### What these add up to

The novel's import today, with the safe changes (3 to 8), and with everything (1 to 8). The second and third figures are estimates, made by taking each change's share off; only today's are measured.

| Format | Today | Safe changes | Everything |
| --- | --- | --- | --- |
| RTF | 195 ms | about 105 ms | about 95 ms |
| DOCX | 153 ms | about 115 ms | about 105 ms |
| EPUB | 90 ms | about 74 ms | about 57 ms |
| HTML | 69 ms | about 64 ms | about 50 ms |
| Plain text | 50 ms | about 34 ms | about 27 ms |
| Markdown | 31 ms | about 26 ms | about 17 ms |

A plain word on what that is worth: one book's import goes from a tenth of a second to a little less, which nobody will notice. It shows when many books are read at once (an archive of books, a folder, or the re-read of the whole library after a cache change), and on the iPhone, where the same code runs on a slower processor. To keep the gains, each change should bring a measurement into `PerformanceBaselineTests`, which today has none for RTF or DOCX reading.

### Measured and not recommended

- **`-O` for the tokeniser's files only**: 61,057 bytes for 6% (section 1.7).
- **Another HTML parser** (lexbor, Gumbo, libxml2, or one written by hand): different trees, so different books (section 1.8).
- **Making the selector engine unreachable**: 85,000 bytes more, but the tests use selectors (section 1.2).
- **Dropping the PDF reader's `page.string` call**: it costs nothing; PDFKit lays the page out once for both calls.
- **A faster checksum**: MD5 is stored in every record and compared across the library, and hashing is under 2% of an import.

## Questions for the user

Each has the answer I recommend.

1. **Shall SwiftSoup be vendored as the trimmed copy?** It makes the app 0.41 MB smaller and the parser 37% faster with the same trees, and puts 32,000 lines of SwiftSoup's source (MIT) under `Vendor/`, written by a script from the pinned release. **Recommended: yes.**
2. **Smallest or fastest?** At `-Osize` the app is 407,072 bytes smaller and the parser 37% faster than today. At `-O` it is 194,400 bytes smaller and the parser 48% faster. **Recommended: smallest**, since the parser is then about a tenth of an EPUB's import, and the difference is about 1% of an import.
3. **Shall the app's 7 `select` calls and the tests' selectors be rewritten as tree walks, so the selector engine goes too?** 85,000 bytes more (0.5% of the app), for edits to 4 source files and to every test that uses a selector. **Recommended: no, not now.**
4. **Shall swift-markdown be replaced by a walk of cmark's own tree?** It is the largest speed gain here and the next largest size saving (0.46 MB), and it rewrites the step every text book passes through. **Recommended: yes, as a task of its own after the safe changes, in a scratch copy first, with the goldens as the gate.** If you would rather not touch that step now, nothing else depends on it.
5. **Shall PDFs be read by two workers?** About 40% off a PDF import. **Recommended: not yet.** Say so if PDF imports are slow enough to bother you, and a trial branch can run the PDF tests many times over to look for trouble.
6. **Shall the safe import changes (3 to 8 above) be done now?** They need no decision of yours, only agent time: one branch, one commit each, RTF and DOCX first. **Recommended: yes.**
7. **May a later agent build and run lexbor and Gumbo to measure their size?** This session refused to run code compiled from downloaded sources, so their sizes above are guesses. **Recommended: no.** The comparison with WebKit already shows that a standard-following parser changes books, whatever its size.

## What I did not verify, and what is on disk

Not verified:

- The golden tests with the trimmed copy in place. The evidence is the 41,100 identical parses and a Release build that links and runs the benchmark. A Debug test build needed about 3 GB and the disk was at 9.1 GB free, so I left it for the branch that builds this.
- The trimmed copy in the iPhone target, in `make check`, and with the hosted tests' linking through the app (section 1.9).
- lexbor's and Gumbo's sizes and trees: not built (section 1.8).
- The user's own books: none was read. Every time is from the generated novel and the repository's test files, which have plainer markup than many published books.
- A first open's profile (H9), and the cause of the memory held for each chapter (H12).
- Each proposal's gain is a share of a profile, not a measurement of the change, except where the text says "measured".

On disk, for the orchestrator to clear when the report has been read:

- `build/orchestrator/nov14/parseresearch/`: 2.1 GB. `tools/` holds every script named here; `logs/` the benchmark results and profiles; `soup/` the SwiftSoup copies and harness; `bench/` the benchmark and its inputs; `alt/` the tree dumps; `dd/` and `dd2/` two Release build folders (0.7 GB each); `app/` a clone of the repository with the vendored copy (it has no remote); `dl/` the lexbor and Gumbo sources, unbuilt.
- The benchmark's sandboxes: 153 folders named `TextMouthTests-<number>` in the system's temporary directory, 1.0 GB together. They are the hosted tests' kind of sandbox, and the next hosted test run sweeps them away as it sweeps a crashed run's (`TextMouthRuntime.removeAbandonedSandboxes`).
