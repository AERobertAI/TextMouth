#!/usr/bin/env python3
"""gen_epubs2.py OUTDIR: more EPUBs: a navigation document in the spine, documents without titles, page-break styles, SVG."""
import os, sys, zipfile
out = sys.argv[1]
os.makedirs(out, exist_ok=True)

class Words:
    def __init__(self, start=500000): self.n = start
    def word(self):
        self.n += 1
        return f"w{self.n:06d}"
    def many(self, count): return " ".join(self.word() for _ in range(count))
w = Words()

XHTML = '<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>\n<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en"><head><title>{title}</title>{head}</head><body>{body}</body></html>'

def make(name, title, documents, points, nav_in_spine=None, css=None, version="3.0"):
    """`documents`: (file, title, body). `points`: (label, href). `nav_in_spine`: the body of a navigation document put first in the spine."""
    path = os.path.join(out, name)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        manifest = "".join(f'<item id="d{i}" href="{f}" media-type="application/xhtml+xml"/>' for i, (f, _, _) in enumerate(documents))
        spine = "".join(f'<itemref idref="d{i}"/>' for i in range(len(documents)))
        head = ""
        if css:
            manifest += '<item id="css" href="s.css" media-type="text/css"/>'
            z.writestr("OEBPS/s.css", css)
            head = '<link rel="stylesheet" type="text/css" href="s.css"/>'
        if nav_in_spine:
            manifest += '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
            spine = '<itemref idref="nav"/>' + spine
            z.writestr("OEBPS/nav.xhtml", XHTML.format(title="Navigation", head="", body=nav_in_spine))
        opf = f'<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="{version}" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>{title}</dc:title><dc:creator>Reviewer Oyelaran</dc:creator><dc:language>en</dc:language><dc:identifier id="id">urn:uuid:{abs(hash(name)) % 10**12:012d}-0000-4000-8000-000000000000</dc:identifier><meta property="dcterms:modified">2026-11-06T00:00:00Z</meta></metadata><manifest>{manifest}<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="ncx">{spine}</spine></package>'
        z.writestr("OEBPS/content.opf", opf)
        nav_points = "".join(f'<navPoint id="n{i}" playOrder="{i}"><navLabel><text>{l}</text></navLabel><content src="{h}"/></navPoint>' for i, (l, h) in enumerate(points, 1))
        z.writestr("OEBPS/toc.ncx", f'<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="x"/></head><docTitle><text>{title}</text></docTitle><navMap>{nav_points}</navMap></ncx>')
        for f, t, body in documents:
            z.writestr("OEBPS/" + f, XHTML.format(title=t, head=head, body=body))
    print(name, os.path.getsize(path))

# A navigation document in the spine: a contents list, a page list, and landmarks, as an EPUB 3 from a publisher has them.
toc_items = "".join(f'<li><a href="c{i}.xhtml">Chapter {i}</a></li>' for i in range(1, 3))
page_items = "".join(f'<li><a href="c1.xhtml#p{n}">{n}</a></li>' for n in range(1, 4))
nav = (f'<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>{toc_items}</ol></nav>'
       f'<nav epub:type="page-list" id="pages"><h2>Pages</h2><ol>{page_items}</ol></nav>'
       f'<nav epub:type="landmarks" id="landmarks"><h2>Guide</h2><ol><li><a epub:type="bodymatter" href="c1.xhtml">Begin Reading</a></li></ol></nav>')
docs = [("c1.xhtml", "Chapter 1", f'<h1>Chapter 1</h1><p>{w.many(10)}<span epub:type="pagebreak" id="p1" title="1"></span>{w.many(10)}</p><p>{w.many(10)}<span epub:type="pagebreak" id="p2" title="2"></span>{w.many(10)}</p><p>{w.many(10)}<span epub:type="pagebreak" id="p3" title="3"></span></p>'),
        ("c2.xhtml", "Chapter 2", f'<h1>Chapter 2</h1><p>{w.many(30)}</p>')]
make("nav-in-spine.epub", "Review Nav", docs, [("Chapter 1", "c1.xhtml"), ("Chapter 2", "c2.xhtml")], nav_in_spine=nav)

# A contents section inside a chapter, by epub:type only, and a footnote section.
docs = [("c1.xhtml", "Front", f'<section epub:type="toc"><h2>In this book</h2><p><a href="c2.xhtml">Chapter 2</a> {w.many(2)}</p></section><h1>Front Matter</h1><p>{w.many(20)}</p>'),
        ("c2.xhtml", "Chapter 2", f'<h1>Chapter 2</h1><p>{w.many(20)}<a epub:type="noteref" href="#n1">1</a></p><section epub:type="footnotes"><aside epub:type="footnote" id="n1"><p>{w.many(5)}</p></aside></section>')]
make("section-toc.epub", "Review Section TOC", docs, [("Front", "c1.xhtml"), ("Chapter 2", "c2.xhtml")])

# Documents that have no useful title and that no contents entry names.
docs = [("a.xhtml", "", f'<p>{w.many(30)}</p>'),
        ("b.xhtml", "Unknown", f'<p>{w.many(30)}</p>'),
        ("c.xhtml", "Review No Titles", f'<p>{w.many(30)}</p>'),
        ("d.xhtml", "Real Title Here", f'<h2>{w.many(2)}</h2><p>{w.many(30)}</p>')]
make("no-titles.epub", "Review No Titles", docs, [("Real", "d.xhtml")])

# Page breaks by style, in the middle of a section.
css = ".brk { page-break-before: always; }\n.aft { page-break-after: always; }\n h1, h2 { color: black; }\n"
body = (f'<h1>Styled Chapter</h1><p>{w.many(40)}</p><p class="brk">{w.many(40)}</p><p>{w.many(40)}</p>'
        f'<p style="page-break-before:always">{w.many(40)}</p><p>{w.many(40)}</p><div class="aft"><p>{w.many(40)}</p></div><p>{w.many(40)}</p>'
        f'<p>{w.many(5)} <span style="page-break-before:always">{w.many(5)}</span> {w.many(5)}</p><h3>{w.many(2)}</h3><p>{w.many(40)}</p>')
make("page-break-style.epub", "Review Page Break Style", [("c.xhtml", "Styled", body), ("d.xhtml", "Second", f'<h1>Second</h1><p>{w.many(30)}</p>')], [("Styled", "c.xhtml"), ("Second", "d.xhtml")], css=css)

# SVG: words in an inline SVG, a title page made of one.
svg_page = f'<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="400" height="300"><title>{w.many(2)}</title><text x="10" y="40">{w.many(3)}</text><text x="10" y="80">{w.many(3)}</text></svg>'
docs = [("t.xhtml", "Title Page", svg_page),
        ("c.xhtml", "Words", f'<h1>Words</h1><p>{w.many(10)}</p><div>{svg_page.replace("w5", "w5")}</div><p>{w.many(10)}</p>')]
make("svg-words.epub", "Review SVG", docs, [("Title", "t.xhtml"), ("Words", "c.xhtml")])

# Each block in a block, and words directly in the body.
docs = [("c.xhtml", "Bare", f'{w.many(5)}<div>{w.many(5)}<div>{w.many(5)}</div>{w.many(5)}</div>{w.many(5)}<p>{w.many(5)}</p>{w.many(5)}')]
make("bare-words.epub", "Review Bare", docs, [("Bare", "c.xhtml")])
