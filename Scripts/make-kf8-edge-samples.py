#!/usr/bin/env python3
"""gen_epubs.py OUTDIR: EPUBs the reviewer feeds to calibre and kindlegen as black boxes, to compare each KF8 with its EPUB.

Every word of a test's prose is a unique token (w00001, ...), so a word lost, doubled, or moved shows at once."""
import os, sys, zipfile
out = sys.argv[1]
os.makedirs(out, exist_ok=True)

class Words:
    """Hands out unique words."""
    def __init__(self): self.n = 0
    def word(self):
        self.n += 1
        return f"w{self.n:06d}"
    def many(self, count): return " ".join(self.word() for _ in range(count))

XHTML = '<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>\n<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en"><head><title>{title}</title></head><body>{body}</body></html>'

def make_epub(name, title, documents, ncx_points, guide=None, version="3.0", nav=False, page_list=None):
    """`documents`: list of (file name, doc title, body). `ncx_points`: list of (label, href, depth)."""
    path = os.path.join(out, name)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        manifest = "".join(f'<item id="d{i}" href="{f}" media-type="application/xhtml+xml"/>' for i, (f, _, _) in enumerate(documents))
        spine = "".join(f'<itemref idref="d{i}"/>' for i in range(len(documents)))
        guide_xml = ""
        if guide:
            guide_xml = "<guide>" + "".join(f'<reference type="{t}" title="{l}" href="{h}"/>' for t, l, h in guide) + "</guide>"
        nav_item = ""
        if nav:
            nav_item = '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
        opf = f'<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="{version}" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>{title}</dc:title><dc:creator>Reviewer Oyelaran</dc:creator><dc:language>en</dc:language><dc:identifier id="id">urn:uuid:{abs(hash(name)) % 10**12:012d}-0000-4000-8000-000000000000</dc:identifier><meta property="dcterms:modified">2026-11-06T00:00:00Z</meta></metadata><manifest>{manifest}<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>{nav_item}</manifest><spine toc="ncx">{spine}</spine>{guide_xml}</package>'
        z.writestr("OEBPS/content.opf", opf)
        # The NCX, nested by depth.
        points = ""
        open_depths = []
        order = 0
        for label, href, depth in ncx_points:
            order += 1
            while open_depths and open_depths[-1] >= depth:
                points += "</navPoint>"
                open_depths.pop()
            points += f'<navPoint id="n{order}" playOrder="{order}"><navLabel><text>{label}</text></navLabel><content src="{href}"/>'
            open_depths.append(depth)
        points += "</navPoint>" * len(open_depths)
        page_xml = ""
        if page_list:
            page_xml = "<pageList><navLabel><text>Pages</text></navLabel>" + "".join(f'<pageTarget id="pg{i}" type="normal" value="{l}" playOrder="{order + i + 1}"><navLabel><text>{l}</text></navLabel><content src="{h}"/></pageTarget>' for i, (l, h) in enumerate(page_list)) + "</pageList>"
        ncx = f'<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="x"/></head><docTitle><text>{title}</text></docTitle><navMap>{points}</navMap>{page_xml}</ncx>'
        z.writestr("OEBPS/toc.ncx", ncx)
        if nav:
            items = "".join(f'<li><a href="{h}">{l}</a></li>' for l, h, d in ncx_points)
            z.writestr("OEBPS/nav.xhtml", XHTML.format(title="Nav", body=f'<nav epub:type="toc" id="toc"><ol>{items}</ol></nav>'))
        for f, t, body in documents:
            z.writestr("OEBPS/" + f, XHTML.format(title=t, body=body))
    print(name, os.path.getsize(path))

w = Words()

# --- features.epub: every construct a reader meets, with a chunk boundary likely anywhere.
long_prose = "".join(f"<p>{w.many(40)} <em>{w.word()}</em> {w.many(5)} <span class=\"x\">{w.many(3)}</span> {w.many(10)}.</p>" for _ in range(300))
big_table = "<table><caption>" + w.many(4) + "</caption><thead><tr><th>" + w.word() + "</th><th>" + w.word() + "</th></tr></thead><tbody>" + "".join(f"<tr><td>{w.many(6)}</td><td colspan=\"1\">{w.many(6)}</td></tr>" for _ in range(600)) + "</tbody></table>"
nested_table = f"<table><tr><td>{w.many(2)}<table><tr><td>{w.many(2)}</td></tr></table>{w.many(2)}</td></tr></table>"
lists = f"<ul><li>{w.many(3)}<ol><li>{w.many(3)}</li><li>{w.many(3)}</li></ol></li><li>{w.many(3)}</li></ul><dl><dt>{w.many(2)}</dt><dd>{w.many(4)}</dd></dl>"
quote = f"<blockquote><p>{w.many(8)}</p><p>{w.many(8)}</p></blockquote>"
pre = f"<pre>{w.word()}  {w.word()}\n   {w.word()}</pre><p><code>{w.word()}</code></p>"
entities = f"<p>{w.word()} &amp; {w.word()} &lt; {w.word()} &#x1F600; {w.word()} 日本語の{w.word()} مرحبا {w.word()} é{w.word()}</p>"
soft = f"<p>{w.word()} pro­duct{w.word()} pro&#173;duct{w.word()} pro&#xAD;duct{w.word()} pro&#xad;duct{w.word()} pro&#xAd;duct{w.word()} pro&#x00AD;duct{w.word()} pro&#00173;duct{w.word()}</p>"
pages = (
    f"<p>{w.many(3)}<span epub:type=\"pagebreak\" id=\"p1\" title=\"101\"></span>{w.many(3)}</p>"
    f"<p>{w.many(3)}<span epub:type=\"pagebreak\" id=\"p2\" aria-label=\"102\"></span>{w.many(3)}</p>"
    f"<p>{w.many(3)}<span role=\"doc-pagebreak\" id=\"p3\" aria-label=\"103\"></span>{w.many(3)}</p>"
    f"<p>{w.many(3)}<span epub:type=\"pagebreak\" role=\"doc-pagebreak\" id=\"p4\" title=\"104\"></span>{w.many(3)}</p>"
    f"<p>{w.many(3)}<span epub:type=\"pagebreak\" id=\"p5\">105</span>{w.many(3)}</p>"
    f"<div epub:type=\"pagebreak\" id=\"p6\" title=\"106\"></div>"
    f"<p>{w.many(3)}<a epub:type=\"pagebreak\" id=\"p7\" title=\"107\"></a>{w.many(3)}</p>"
    f"<p>{w.many(3)}<span epub:type=\"pagebreak bodymatter\" id=\"p8\" title=\"108\"></span>{w.many(3)}</p>"
    f"<p>{w.many(3)}<span data-type=\"pagebreak\" id=\"p9\" title=\"109\">{w.word()}</span>{w.many(3)}</p>"
    f"<ol type=\"a\"><li>{w.many(3)}</li></ol>"
)
media = (
    f"<p><img src=\"data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7\" alt=\"{w.many(3)}\"/></p>"
    f"<p>{w.many(2)}<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"30\"><title>{w.many(2)}</title><desc>{w.many(2)}</desc><text x=\"0\" y=\"15\">{w.many(3)}</text></svg>{w.many(2)}</p>"
    f"<p>{w.many(2)}<math xmlns=\"http://www.w3.org/1998/Math/MathML\" alttext=\"{w.word()}\"><mi>{w.word()}</mi></math>{w.many(2)}</p>"
    f"<p><ruby>{w.word()}<rt>{w.word()}</rt></ruby></p>"
    f"<aside epub:type=\"footnote\" id=\"fn1\"><p>{w.many(5)}</p></aside>"
    f"<details><summary>{w.word()}</summary><p>{w.many(3)}</p></details>"
    f"<p hidden=\"hidden\">{w.many(3)}</p>"
    f"<!-- {w.word()} -->"
    f"<figure><figcaption>{w.many(3)}</figcaption></figure>"
    f"<section><h3>{w.many(2)}</h3><p>{w.many(3)}</p></section>"
)
hard = f"<p>{w.word()}<br/>{w.word()}<br/>{w.word()}</p><hr/><p>{w.word()}</p><h4 id=\"deep\">{w.many(2)}</h4><p>{w.many(3)}</p>"
docs = [
    ("c1.xhtml", "One", f"<h1>{w.many(2)}</h1>" + long_prose),
    ("c2.xhtml", "Two", f"<h1>{w.many(2)}</h1>" + big_table + nested_table + lists + quote + pre + entities),
    ("c3.xhtml", "Three", f"<h1>{w.many(2)}</h1>" + soft + pages + media + hard),
]
make_epub("features.epub", "Review Features", docs, [("One", "c1.xhtml", 0), ("Two", "c2.xhtml", 0), ("Three", "c3.xhtml", 0), ("Deep", "c3.xhtml#deep", 1)])

# --- A real contents page: last in the book, in the guide, and not in the NCX.
def small_docs():
    return [(f"c{i}.xhtml", f"Doc {i}", f"<h1>Heading {i} {w.word()}</h1><p>{w.many(30)}</p>") for i in range(1, 4)]
contents_body = "<h2>Table des matières</h2><p>" + w.many(6) + "</p><p><a href=\"c1.xhtml\">Chapitre premier " + w.word() + "</a></p><p><a href=\"c2.xhtml\">Chapitre deux " + w.word() + "</a></p><p>" + w.many(30) + " an author's note about the book that a person would read.</p>"
docs = small_docs()
docs.append(("tdm.xhtml", "Table des matières", contents_body))
make_epub("toc-last.epub", "Review TOC Last", docs, [(f"Doc {i}", f"c{i}.xhtml", 0) for i in range(1, 4)], guide=[("toc", "Table des matières", "tdm.xhtml"), ("text", "Start", "c1.xhtml")], version="2.0")

# --- One document holds the whole book, and the guide names a contents list inside it.
single = "<h1 id=\"top\">The Whole Book " + w.word() + "</h1><div id=\"toc\"><h2>Contents</h2><p><a href=\"#a\">Part A</a></p><p><a href=\"#b\">Part B</a></p></div>"
single += "<h2 id=\"a\">Part A</h2><p>" + w.many(200) + "</p><h3>Sub</h3><p>" + w.many(200) + "</p><h2 id=\"b\">Part B</h2><p>" + w.many(200) + "</p>"
make_epub("toc-single.epub", "Review Single", [("all.xhtml", "All", single)], [("Part A", "all.xhtml#a", 0), ("Part B", "all.xhtml#b", 0)], guide=[("toc", "Contents", "all.xhtml#toc")], version="2.0")

# --- The last document holds the last chapter and then its contents list, which the guide names.
mixed = "<h1>The Last Chapter " + w.word() + "</h1><p>" + w.many(400) + "</p><div id=\"tdm\"><h2>Table des matières</h2><p><a href=\"c1.xhtml\">One</a></p></div>"
docs = small_docs()
docs.append(("last.xhtml", "Last", mixed))
make_epub("toc-mixed.epub", "Review TOC Mixed", docs, [(f"Doc {i}", f"c{i}.xhtml", 0) for i in range(1, 4)], guide=[("toc", "Table des matières", "last.xhtml#tdm")], version="2.0")

# --- A contents page last, whose first word is a chapter's: no h1 or h2.
docs = small_docs()
docs.append(("epilogue.xhtml", "Epilogue", "<p>" + w.many(300) + "</p>"))
make_epub("toc-epilogue.epub", "Review Epilogue", docs, [(f"Doc {i}", f"c{i}.xhtml", 0) for i in range(1, 4)], guide=[("toc", "Epilogue", "epilogue.xhtml")], version="2.0")

# --- One long chapter with no heading after the first: where do parts begin?
long_doc = "<h1>Only Heading " + w.word() + "</h1>" + "".join(f"<p>{w.many(60)}</p>" for _ in range(6000))
make_epub("long-chapter.epub", "Review Long", [("long.xhtml", "Long", long_doc)], [("Only", "long.xhtml", 0)], version="2.0")

# --- Page breaks named by a page list only, as most EPUB 3 from publishers are.
pl_doc = "".join(f"<p>{w.many(20)}<span epub:type=\"pagebreak\" id=\"pg{n}\"></span>{w.many(20)}</p>" for n in range(1, 6))
make_epub("page-list.epub", "Review Page List", [("c.xhtml", "C", "<h1>Pages</h1>" + pl_doc)], [("C", "c.xhtml", 0)], page_list=[(str(n), f"c.xhtml#pg{n}") for n in range(1, 6)])
