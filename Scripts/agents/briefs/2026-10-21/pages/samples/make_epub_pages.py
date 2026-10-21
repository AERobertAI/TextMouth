#!/usr/bin/env python3
"""Make the three synthetic EPUB samples that exercise page lists and page breaks (PG05).

    python3 -I make_epub_pages.py [OUTPUT_FOLDER]

OUTPUT_FOLDER defaults to TestData/format-samples of this repository; the
script writes epub3-pages/page-list.epub, epub3-pages/pagebreaks-only.epub, and
epub2-pages/pagelist.epub beneath it. The files are byte-for-byte repeatable
(fixed timestamps, fixed member order), so `samples.tsv` can record their
sha256. Every word in them is invented for the test: CC0-1.0.

What each sample holds (the tests in EPUBPageListTests read these places):

  epub3-pages/page-list.epub   EPUB 3, a TOC nav and a page-list nav, two chapters.
      Pages i, ii, 1, 2, 3, 3, 4 and an entry ("H1") whose target is hidden:
        i   the first chapter's start (an entry with no fragment)
        ii  an empty <span id="pii"/> before the first paragraph
        1   <span epub:type="pagebreak" id="p1" title="1">1</span> mid-paragraph
        2   an h2 with an id (which the TOC names too)
        3   inside a word: "tele<span id="p3" .../>phone"
        3   <p id="p3b"> (a second page labelled 3)
        H1  a paragraph inside a hidden div (dropped)
        4   the second chapter's first paragraph, by fragment
      It also holds a page-break element the list does not name, with the
      text "99".
  epub3-pages/pagebreaks-only.epub   EPUB 3 with no page list. Page-break
      elements labelled by aria-label ("5"), by title ("6", inside a heading),
      and by text ("7"), and one with no label at all (not a page).
  epub2-pages/pagelist.epub   EPUB 2, an NCX navMap and a pageList of three
      pageTargets, one with an empty navLabel text and value="3".
"""
import sys
import zipfile
from pathlib import Path

# Every member gets this timestamp so the archives repeat byte for byte.
STAMP = (2026, 10, 21, 0, 0, 0)

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
"""


def write_epub(path, members):
    """Write an EPUB at `path`: the stored mimetype member first, then `members`
    (a list of (name, text) pairs) in the order given, deflated."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as archive:
        info = zipfile.ZipInfo("mimetype", STAMP)
        info.compress_type = zipfile.ZIP_STORED
        archive.writestr(info, "application/epub+zip")
        for name, text in members:
            info = zipfile.ZipInfo(name, STAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, text.encode("utf-8"))


def xhtml(title, body, namespaces='xmlns:epub="http://www.idpf.org/2007/ops"'):
    """An XHTML chapter document holding `body`."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" {namespaces}>
<head><title>{title}</title></head>
<body>
{body}
</body>
</html>
"""


def opf(version, title, author, uid, items, spine, extra_spine_attributes=""):
    """A package document. `items` are (id, href, media-type, properties) tuples."""
    manifest = "\n".join(
        f'<item id="{i}" href="{href}" media-type="{kind}"' + (f' properties="{props}"' if props else "") + "/>"
        for i, href, kind, props in items
    )
    itemrefs = "\n".join(f'<itemref idref="{i}"/>' for i in spine)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="{version}" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="id">{uid}</dc:identifier>
<dc:title>{title}</dc:title>
<dc:creator>{author}</dc:creator>
<dc:language>en</dc:language>
</metadata>
<manifest>
{manifest}
</manifest>
<spine{extra_spine_attributes}>
{itemrefs}
</spine>
</package>
"""


def make_page_list(out):
    """epub3-pages/page-list.epub."""
    chapter1 = xhtml("First Delivery", """<h1>First Delivery</h1>
<span id="pii"/>
<p>The crate came in on a Tuesday and sat by the door <span epub:type="pagebreak" id="p1" title="1">1</span>until somebody signed for it.</p>
<h2 id="p2">Opening the Crate</h2>
<p>Inside lay a brass tele<span id="p3" epub:type="pagebreak" title="3"/>phone and a coil of cable.</p>
<p id="p3b">The coil was wound tight and its label was smudged.</p>
<p>Someone had pencilled a note <span epub:type="pagebreak" id="p99">99</span>in the margin.</p>
<div hidden="hidden"><p id="phidden">This paragraph is not shown to anyone.</p></div>""")
    chapter2 = xhtml("Second Delivery", """<h1>Second Delivery</h1>
<p id="p4">The second crate held only straw and a receipt.</p>""")
    nav = xhtml("Contents", """<nav epub:type="toc"><ol>
<li><a href="ch1.xhtml">First Delivery</a>
<ol><li><a href="ch1.xhtml#p2">Opening the Crate</a></li></ol></li>
<li><a href="ch2.xhtml">Second Delivery</a></li>
</ol></nav>
<nav epub:type="page-list" hidden="hidden"><ol>
<li><a href="ch1.xhtml">i</a></li>
<li><a href="ch1.xhtml#pii">ii</a></li>
<li><a href="ch1.xhtml#p1">1</a></li>
<li><a href="ch1.xhtml#p2">2</a></li>
<li><a href="ch1.xhtml#p3">3</a></li>
<li><a href="ch1.xhtml#p3b">3</a></li>
<li><a href="ch1.xhtml#phidden">H1</a></li>
<li><a href="ch2.xhtml#p4">4</a></li>
</ol></nav>""")
    write_epub(out / "epub3-pages" / "page-list.epub", [
        ("META-INF/container.xml", CONTAINER),
        ("OEBPS/content.opf", opf("3.0", "Crates and Pages", "Odalys Brekke", "urn:textmouth:sample:epub3-page-list",
            [("nav", "nav.xhtml", "application/xhtml+xml", "nav"),
             ("ch1", "ch1.xhtml", "application/xhtml+xml", ""),
             ("ch2", "ch2.xhtml", "application/xhtml+xml", "")],
            ["ch1", "ch2"])),
        ("OEBPS/nav.xhtml", nav),
        ("OEBPS/ch1.xhtml", chapter1),
        ("OEBPS/ch2.xhtml", chapter2),
    ])


def make_pagebreaks_only(out):
    """epub3-pages/pagebreaks-only.epub."""
    chapter = xhtml("Survey Notes", """<h1>Survey Notes</h1>
<p>The first sheet closes with the tide tables. <span epub:type="pagebreak" aria-label="5">V</span>The second sheet opens with the gauge readings.</p>
<p>Nothing was written here.<span epub:type="pagebreak"/> The unmarked break joins two sentences.</p>
<h2>Survey <span epub:type="pagebreak" title="6"/>Methods</h2>
<p>Readings were taken at noon. <span role="doc-pagebreak">7</span>Each was checked twice.</p>""")
    nav = xhtml("Contents", """<nav epub:type="toc"><ol>
<li><a href="ch1.xhtml">Survey Notes</a></li>
</ol></nav>""")
    write_epub(out / "epub3-pages" / "pagebreaks-only.epub", [
        ("META-INF/container.xml", CONTAINER),
        ("OEBPS/content.opf", opf("3.0", "Survey Notes", "Ingrid Vasquez-Holm", "urn:textmouth:sample:epub3-pagebreaks",
            [("nav", "nav.xhtml", "application/xhtml+xml", "nav"),
             ("ch1", "ch1.xhtml", "application/xhtml+xml", "")],
            ["ch1"])),
        ("OEBPS/nav.xhtml", nav),
        ("OEBPS/ch1.xhtml", chapter),
    ])


def make_epub2_pagelist(out):
    """epub2-pages/pagelist.epub."""
    chapter1 = xhtml("The Weighing", """<h1>The Weighing</h1>
<p id="pa1">Each sack was weighed twice before it left the yard.</p>
<p>The foreman wrote the figure <span id="pa3"/>on a slate and wiped it clean again.</p>""", namespaces="")
    chapter2 = xhtml("The Count", """<h1>The Count</h1>
<div id="pa4"><p>At dusk the tally was read out loud, sack by sack.</p></div>""", namespaces="")
    ncx = """<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="urn:textmouth:sample:epub2-pagelist"/></head>
<docTitle><text>Sacks and Slates</text></docTitle>
<navMap>
<navPoint id="n1" playOrder="1"><navLabel><text>The Weighing</text></navLabel><content src="ch1.xhtml"/></navPoint>
<navPoint id="n2" playOrder="2"><navLabel><text>The Count</text></navLabel><content src="ch2.xhtml"/></navPoint>
</navMap>
<pageList>
<navLabel><text>Pages</text></navLabel>
<pageTarget id="pt1" type="normal" value="1" playOrder="3"><navLabel><text>A-1</text></navLabel><content src="ch1.xhtml#pa1"/></pageTarget>
<pageTarget id="pt2" type="normal" value="3" playOrder="4"><navLabel><text></text></navLabel><content src="ch1.xhtml#pa3"/></pageTarget>
<pageTarget id="pt3" type="normal" value="4" playOrder="5"><navLabel><text>4</text></navLabel><content src="ch2.xhtml#pa4"/></pageTarget>
</pageList>
</ncx>
"""
    write_epub(out / "epub2-pages" / "pagelist.epub", [
        ("META-INF/container.xml", CONTAINER),
        ("OEBPS/content.opf", opf("2.0", "Sacks and Slates", "Tobias Lindqvist-Amadi", "urn:textmouth:sample:epub2-pagelist",
            [("ncx", "toc.ncx", "application/x-dtbncx+xml", ""),
             ("ch1", "ch1.xhtml", "application/xhtml+xml", ""),
             ("ch2", "ch2.xhtml", "application/xhtml+xml", "")],
            ["ch1", "ch2"], extra_spine_attributes=' toc="ncx"')),
        ("OEBPS/toc.ncx", ncx),
        ("OEBPS/ch1.xhtml", chapter1),
        ("OEBPS/ch2.xhtml", chapter2),
    ])


def main():
    # The repository root is six folders above this file's folder.
    default = Path(__file__).resolve().parents[6] / "TestData" / "format-samples"
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else default
    make_page_list(out)
    make_pagebreaks_only(out)
    make_epub2_pagelist(out)


if __name__ == "__main__":
    main()
