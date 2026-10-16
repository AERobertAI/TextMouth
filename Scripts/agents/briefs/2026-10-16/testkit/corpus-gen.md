# testkit/corpus-gen: a generator of nasty-but-valid documents, `Scripts/test/make-corpus.py`

Slug `testkit-corpus-gen`. Branch `testkit/corpus-gen`, made from `team/testkit`. Python 3 standard library only. **You build nothing and you never run the app.** Read `teams-common.md`'s worker's part first.

## Why

The acceptance matrix's "Real documents" row (TODO-2026-09-04.md line 3641) asks to try "representative EPUB 2/3, DAISY 2.02/3, DOCX lists/tables, scanned/mixed/column PDFs, very long Markdown, and large Unicode-heavy books", and T10 (line 3535) asks about PDF reading order. The user may not have such files to hand. A later task (`testkit-corpus-report`) reads any folder of documents through TextMouth's importers and writes a report; this task makes a folder worth reading: deterministic, small by default, each file named for the hazard it carries, each valid so that a failure is the importer's, not the file's.

## The command

    make-corpus.py [--out DIR] [--seed N] [--large] [--selftest] [-h]

- `--out DIR`: default `<tempdir>/textmouth-corpus` (`tempfile.gettempdir()`); created if missing; refuse a folder that already holds files that this script did not write (check for its `corpus-manifest.json`); an existing corpus folder is replaced file by file.
- `--seed N`: the generator for any "random" content is `random.Random(N)` (default 20261016); the same seed gives byte-identical files (zip timestamps fixed to 2020-01-01, entries in a fixed order). Prove it in the selftest (two runs, same SHA-256 for every file).
- default size: every file under 300 KB, whole corpus under 6 MB. `--large` adds the heavy ones: a 5 MB Markdown, a 3 MB single-line text file, a 40-chapter EPUB.
- Output: one line per file written (name and size), then `corpus-manifest.json` (file name, format, hazard sentence, expected title/author/heading count where the generator knows them), and a last line `wrote N files to DIR`. Plain words; no color, no emoji (VoiceOver and braille reader).

## The files (names carry the hazard; write each in its own small function, commented)

EPUB (build with `zipfile`; `mimetype` first and STORED; fixed timestamps):
- `epub2-ncx-nested.epub`: EPUB 2, NCX with nested navPoints three deep, chapters with h1 to h4 and in-page anchors.
- `epub3-nav-landmarks.epub`: EPUB 3, `nav.xhtml` with `epub:type="toc"`, `landmarks`, a `page-list`, a hidden TOC branch, `dcterms:modified`, two creators with `opf:role`/`refines` roles and `file-as`.
- `epub3-no-nav-spine-only.epub`: valid EPUB 3 whose spine has chapters but whose nav lists only the first.
- `epub2-latin-entities.epub`: entities (`&eacute;`, `&nbsp;`, `&#x2014;`), curly quotes, a `<br/>` run, a footnote link.
DOCX (hand-written WordprocessingML, `zipfile`):
- `docx-headings-lists-tables.docx`: Title style, Heading 1 to 6, `w:outlineLvl` paragraphs (including level 9, which means no outline level), bullets and numbered lists nested three levels deep, a table with a header row and merged cells, a hyperlink, tabs, soft line breaks, empty paragraphs, core properties with title and creator.
- `docx-no-styles.docx`: plain paragraphs only, no styles part.
Markdown, text, HTML:
- `markdown-feature-soup.md`: setext and ATX headings 1 to 6, tables with alignment, fenced code, nested lists, block quotes, footnotes, link references, inline HTML, hard breaks.
- `markdown-very-long.md` (only with `--large`, 5 MB): 400 sections, repeated structure, a table every 20 sections.
- `unicode-heavy.md`: Arabic and Hebrew (right to left), Chinese, Japanese, Korean, Thai (no spaces), Devanagari, emoji with zero-width-joiner sequences and skin tones and flags, decomposed accents (`e` + U+0301), astral-plane characters, variation selectors, soft hyphens, no-break spaces, U+2028/U+2029, a stray BOM mid-text, and bidirectional controls (U+202E). Each hazard on its own labelled line.
- `text-utf8.txt`, `text-utf16le-bom.txt`, `text-utf16be-bom.txt`, `text-latin1.txt`, `text-windows1252.txt`, `text-crlf.txt`, `text-cr-only.txt`, `text-form-feeds.txt`, `text-all-caps-headings.txt` (heading heuristics), and `text-one-long-line.txt` (3 MB, `--large` only): the same short passage in each encoding or line-ending style.
- `html-nested-soup.html`: nested sections, tables, `<pre>`, scripts and styles that must not be read, `&nbsp;` runs, `<br><br>` paragraphs, h1 to h6, `<meta charset="windows-1252">` with matching bytes.
PDF (stretch goal, hand-written PDF syntax with Helvetica and correct xref offsets, no images):
- `pdf-one-column.pdf`, `pdf-two-columns.pdf` (left column then right), `pdf-two-columns-drawn-backwards.pdf` (the right column's text is drawn FIRST in the content stream, so stream order is not reading order), `pdf-rotated-90.pdf` and `pdf-rotated-270.pdf` (`/Rotate` on the page), `pdf-with-outline.pdf` (an `/Outlines` tree naming headings that also appear as body lines, for the duplicate-heading heuristic).
Skip DAISY and scanned PDFs: say so in the manifest (a `skipped` list with the reason).

## Selftest (`--selftest`, no network, uses a temp folder)

For every file: EPUB is a ZIP whose first entry is `mimetype` stored, `META-INF/container.xml` names an OPF that exists, every spine item exists, every XML part parses with `xml.etree`; DOCX parts parse and `[Content_Types].xml` covers each part; PDF: every xref offset points at `<n> 0 obj`, `startxref` is right, the trailer's `/Size` is right; text files decode with the encoding their name says; the manifest lists every file and nothing else; two runs with the same seed are byte-identical; a different seed changes at least the Markdown soup. Print `selftest: N checks, all passed` or one line per failure; exit 0 or 1.

## Commits

1. EPUB and DOCX writers, the manifest, the command line, the selftest.
2. Markdown, text, and HTML files.
3. PDFs (if you reach them).

## Do not

Edit any other file. Use any package outside the standard library. Write outside `--out` and the temp folder. Create a file bigger than the limits above.

## Report (at most 15 lines)

Branch; commits; the list of files with sizes (`make-corpus.py --out <scratch>`); the selftest result; what you could not verify (you cannot open these files in TextMouth: say which structural checks stand in for that).
