#!/usr/bin/env python3
"""Makes the small KFX sample books of TestData/format-samples/kfx (FMT52).

The book is written here, so it is CC0-1.0: a small EPUB 3 holding everything
the KFX walk has to meet (headings 1 to 6, bold and italic, both, inside a
word and overlapping, nested lists, a table with merged cells, footnotes, links,
a picture with alt text, a page list, landmarks, a block quote, a poem with
line breaks). The EPUB is kept beside the books Amazon's Kindle Previewer
makes from it:

  kfx-features.epub   the source, which the tests compare the reading with
  kfx-features.kfx    EPUB to KPF to KFX by Previewer and calibre's plugin
  kfx-features.kpf    the package Previewer made on the way

The conversion runs through `kfx_tools.sh`, which takes the heavy-work lock
and runs the tools as black boxes; this script reads neither tool's code.
Previewer stamps a new identifier into every run, so the bytes differ each
time; the files in the repository are the ones the tests were written
against, and their sha256 is in samples.tsv.

Usage: python3 -I Scripts/make-kfx-sample.py [output-folder] [--inline-only] [--epub-only]
The default folder is TestData/format-samples/kfx. With --epub-only the EPUB
alone is written, which needs no tool.
"""
import os
import struct
import subprocess
import sys
import zipfile
import zlib

REPOSITORY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_FOLDER = os.path.join(REPOSITORY, "TestData/format-samples/kfx")
# The black-box tool lives in the main checkout's gitignored build folder.
KFX_TOOLS = os.environ.get("KFX_TOOLS", os.path.join(
    REPOSITORY, "build/orchestrator/followups1105/kindle-previewer/kfx_tools.sh"))

# A fixed timestamp, so the EPUB's bytes are the same at every run.
ZIP_TIME = (2026, 11, 6, 0, 0, 0)

PAGE_BREAK = '<span epub:type="pagebreak" role="doc-pagebreak" id="p{n}" aria-label="{n}"/>'


def page(number):
    """The empty element that starts print page `number`."""
    return PAGE_BREAK.format(n=number)


# The chapters: (file name, title, body). The tests look for these sentences,
# so change them only together with KFXEPUBComparisonTests.
CHAPTERS = [
    ("ch1.xhtml", "Chapter One: Headings and Emphasis", f"""
<h1 id="c1">Chapter One: Headings and Emphasis</h1>
{page(1)}
<p>The tool library opens on Tuesday evenings, and the first rule on its door is that nothing leaves without a name beside it.</p>
<h2 id="h2">The Level Two Heading</h2>
<p>A plain paragraph sits under it, with <strong>bold words</strong>, <em>italic words</em>, and <strong><em>words that are both</em></strong>.</p>
<h3 id="h3">The Level Three Heading</h3>
<p>Emphasis may start inside a word: un<strong>believ</strong>able, and <em>re</em>build. It may also run across a boundary: <strong>bold begins <em>and italics begin</em> and bold ends</strong> <em>before italics end</em>.</p>
<h4 id="h4">The Level Four Heading</h4>
<p>The drill is kept on the second shelf.</p>
<h5 id="h5">The Level Five Heading</h5>
<p>The ladder is kept on the hooks by the window.</p>
<h6 id="h6">The Level Six Heading</h6>
<p>The spirit level is kept in a drawer of its own.</p>
{page(2)}
<h2 id="h2b">A Second Section</h2>
<p>Saws are lent for a week. Hammers are lent for a month, since nobody has ever needed one for longer.</p>
"""),
    ("ch2.xhtml", "Chapter Two: Lists and Tables", f"""
<h1 id="c2">Chapter Two: Lists and Tables</h1>
{page(3)}
<p>The stock is listed by shelf.</p>
<ol>
  <li>First shelf
    <ul>
      <li>Hammers</li>
      <li>Mallets
        <ol>
          <li>Rubber</li>
          <li>Wooden</li>
        </ol>
      </li>
    </ul>
  </li>
  <li>Second shelf</li>
  <li>Third shelf</li>
</ol>
<table>
  <caption>Loans by season</caption>
  <thead><tr><th>Season</th><th colspan="2">Loans</th></tr></thead>
  <tbody>
    <tr><td rowspan="2">Spring</td><td>Hand tools</td><td>Forty</td></tr>
    <tr><td>Power tools</td><td>Twelve</td></tr>
    <tr><td>Autumn</td><td>Hand tools</td><td>Thirty</td></tr>
  </tbody>
</table>
<p>The table is the whole of the ledger.</p>
"""),
    ("ch3.xhtml", "Chapter Three: Notes, Links and Pictures", f"""
<h1 id="c3">Chapter Three: Notes, Links and Pictures</h1>
{page(4)}
<p>The ladder has a history<a epub:type="noteref" href="#fn1" id="r1">1</a> that the oldest member tells at length.</p>
<blockquote><p>A tool unlent is a tool unloved.</p></blockquote>
<p>Read the rules at <a href="https://example.org/rules">the rules page</a>, or go back to <a href="ch1.xhtml#h2">the level two heading</a>.</p>
<p><img src="plan.png" alt="A floor plan of the tool library"/></p>
<p class="poem">The saw goes out on Monday,<br/>the saw comes back on Friday,<br/>and nobody asks where it has been.</p>
{page(5)}
<p>The last paragraph of the book is short.</p>
<aside epub:type="footnote" id="fn1"><p>It was bought second-hand from a school that closed.</p></aside>
"""),
]


# A second small book for the pictures, math, and spans that sit inside a
# paragraph: Amazon stores such a paragraph as strings and nodes in one list.
# The tests look for these sentences (KFXInlineBookTests).
INLINE_CHAPTERS = [
    ("ch1.xhtml", "Inline Things", f"""
<h1 id="i1">Inline Things</h1>
{page(1)}
<p>Text then <img src="plan.png" alt=""/> more text.</p>
<p>Before picture <img src="plan.png" alt="first inline alt"/> middle words after the page.</p>
<p><img src="plan.png" alt="first of two"/> <img src="plan.png" alt="second of two"/></p>
<h2 id="i2">Heading <img src="plan.png" alt="x"/> words</h2>
<p>Text <span style="float:right">floated span words</span> tail.</p>
<ul><li>Item with <img src="plan.png" alt="item picture"/> inside</li></ul>
<table><tr><td>Cell with <img src="plan.png" alt="cell picture"/> inside</td><td>Plain cell</td></tr></table>
<p>Math inline <math xmlns="http://www.w3.org/1998/Math/MathML" alttext="y equals two"><mi>y</mi><mo>=</mo><mn>2</mn></math> done.</p>
<p>Words before{page(2)} and after the page.</p>
<p>Bold start <em>and an emphasised <img src="plan.png" alt="inner"/> picture</em> then end.</p>
<h2 id="i3"><img src="plan.png" alt="Picture Only Heading"/></h2>
<p><em>Whole paragraph in em.</em></p>
<p>Number shown before<span epub:type="pagebreak" role="doc-pagebreak" id="p11" aria-label="11">11</span> and after.</p>
<h2 id="i4">Alpha <span style="float:right">fl words</span> gamma</h2>
<p><span style="float:right">Floated first</span> then the remaining words</p>
"""),
    ("ch2.xhtml", "Second Part", """
<h1 id="j1">Second Part</h1>
<table><thead><tr><th>Row head</th><th>Next head</th></tr></thead>
<tbody><tr><td>Row value</td><td>Next value</td></tr></tbody></table>
<p style="page-break-after:always">Before the cut.</p>
<p>After the cut, in a new section with no heading.</p>
"""),
]
INLINE_PAGES = [("ch1.xhtml", 1), ("ch1.xhtml", 2), ("ch1.xhtml", 11)]


def png(width=8, height=8):
    """A small grey PNG, made by hand so no image library is needed."""
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)
    rows = b"".join(b"\x00" + bytes([0x80] * width) for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def xhtml(title, body):
    """A chapter's XHTML document around `body`."""
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">\n'
        f'<head><meta charset="utf-8"/><title>{title}</title></head>\n'
        f'<body>{body}</body>\n</html>\n')


FEATURE_PAGES = [("ch1.xhtml", 1), ("ch1.xhtml", 2), ("ch2.xhtml", 3), ("ch3.xhtml", 4), ("ch3.xhtml", 5)]


def navigation(chapters, page_entries):
    """The EPUB 3 navigation document: contents, page list, landmarks."""
    toc = "".join(f'<li><a href="{name}">{title}</a></li>' for name, title, _ in chapters if title)
    pages = "".join(f'<li><a href="{name}#p{n}">{n}</a></li>' for name, n in page_entries)
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">\n'
        '<head><meta charset="utf-8"/><title>Contents</title></head>\n<body>\n'
        f'<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>{toc}</ol></nav>\n'
        f'<nav epub:type="page-list" hidden="hidden"><ol>{pages}</ol></nav>\n'
        '<nav epub:type="landmarks" hidden="hidden"><ol>'
        '<li><a epub:type="bodymatter" href="ch1.xhtml">Start of the book</a></li>'
        '</ol></nav>\n</body>\n</html>\n')


def package(chapters, book_title, identifier, mathml=False):
    """The package document (OPF)."""
    math = ' properties="mathml"' if mathml else ""
    items = "".join(
        f'<item id="ch{i}" href="{name}" media-type="application/xhtml+xml"{math}/>'
        for i, (name, _, _) in enumerate(chapters, 1))
    spine = "".join(f'<itemref idref="ch{i}"/>' for i in range(1, len(chapters) + 1))
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="en">\n'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        f'<dc:identifier id="uid">urn:uuid:{identifier}</dc:identifier>\n'
        f'<dc:title>{book_title}</dc:title>\n'
        '<dc:creator>Test Author</dc:creator>\n'
        '<dc:language>en</dc:language>\n'
        '<meta property="dcterms:modified">2026-11-06T00:00:00Z</meta>\n'
        '</metadata>\n<manifest>\n'
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\n'
        f'{items}\n'
        '<item id="plan" href="plan.png" media-type="image/png"/>\n'
        f'</manifest>\n<spine>{spine}</spine>\n</package>\n')


def write_epub(path, chapters=None, page_entries=None, book_title="The Tool Library Handbook",
               identifier="5b1e3a0e-7a47-4f0e-9a4e-6b6b0d6f0c11", mathml=False):
    """Writes a sample EPUB to `path`, the same bytes at every run."""
    chapters = CHAPTERS if chapters is None else chapters
    page_entries = FEATURE_PAGES if page_entries is None else page_entries
    container = (
        '<?xml version="1.0"?>\n'
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
        '</rootfiles></container>\n')
    files = [("mimetype", "application/epub+zip", zipfile.ZIP_STORED),
             ("META-INF/container.xml", container, zipfile.ZIP_DEFLATED),
             ("OEBPS/content.opf", package(chapters, book_title, identifier, mathml), zipfile.ZIP_DEFLATED),
             ("OEBPS/nav.xhtml", navigation(chapters, page_entries), zipfile.ZIP_DEFLATED),
             ("OEBPS/plan.png", png(), zipfile.ZIP_STORED)]
    files += [(f"OEBPS/{name}", xhtml(title, body), zipfile.ZIP_DEFLATED) for name, title, body in chapters]
    with zipfile.ZipFile(path, "w") as archive:
        for name, content, method in files:
            info = zipfile.ZipInfo(name, ZIP_TIME)
            info.compress_type = method
            archive.writestr(info, content.encode("utf-8") if isinstance(content, str) else content)


def main():
    arguments = [a for a in sys.argv[1:] if not a.startswith("--")]
    folder = arguments[0] if arguments else DEFAULT_FOLDER
    os.makedirs(folder, exist_ok=True)
    # --inline-only makes just the inline book (the features book's KFX is
    # kept as it is: Previewer stamps new identifiers into every run).
    books = [] if "--inline-only" in sys.argv else [("kfx-features", None)]
    for name, kind in books + [("kfx-inline", "inline")]:
        epub = os.path.join(folder, name + ".epub")
        if kind == "inline":
            write_epub(epub, INLINE_CHAPTERS, INLINE_PAGES, "Inline Things Handbook",
                       "7c2f3e0a-1d6b-4c53-8a77-2f6b6a0e9d12", mathml=True)
        else:
            write_epub(epub)
        print("wrote", epub)
        if "--epub-only" in sys.argv:
            continue
        kfx = os.path.join(folder, name + ".kfx")
        subprocess.run([KFX_TOOLS, "make", epub, kfx], check=True)
        print("wrote", kfx)


if __name__ == "__main__":
    main()
