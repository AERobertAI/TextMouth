#!/usr/bin/env python3
"""make-corpus.py: write a folder of nasty-but-valid documents for TextMouth's importers.

Every file is well formed (so a failure to read it is the importer's, not the
file's), small by default, deterministic for a given seed, and named for the
hazard it carries.  A later tool reads any folder of documents through the
importers and writes a report; this script makes a folder worth reading.

Usage:
    make-corpus.py [--out DIR] [--seed N] [--large] [--selftest] [-h]

Only the Python 3 standard library is used.  The output is plain words (no
color, no emoji), so VoiceOver and a braille display read it cleanly.
"""

import argparse
import hashlib
import json
import posixpath
import random
import re
import sys
import tempfile
import uuid
import zipfile
from dataclasses import dataclass, field
from html.entities import name2codepoint
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote
from xml.sax.saxutils import escape
import xml.etree.ElementTree as ET

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------

GENERATOR_ID = "make-corpus.py"        # stamped in the manifest to recognise our own folders
MANIFEST_NAME = "corpus-manifest.json"  # the manifest file's name inside the corpus folder
DEFAULT_SEED = 20261016                 # the seed that "no --seed" means
FIXED_ZIP_TIME = (2020, 1, 1, 0, 0, 0)  # every zip entry carries this timestamp (byte-identical output)
MAX_FILE_BYTES = 300_000                # default size cap for one file
MAX_CORPUS_BYTES = 6_000_000            # default size cap for the whole corpus

# A neutral word bank for generated filler prose.  Plain words, no names.
WORDS = (
    "harbor ledger copper orchard signal meridian tannery almanac foundry compass "
    "lantern barrel gravel timber crossing station bridge market cellar meadow "
    "quarry kettle anchor ribbon thimble bucket window shelf ladder pillar cabinet "
    "garden furnace letter parcel engine summit valley canal tunnel granary wagon "
    "saddle button needle thread basket mirror pencil drawer corner chapter river "
    "morning evening season harvest weather journey promise question answer measure "
    "careful quiet steady narrow distant ordinary patient crooked bright hollow "
    "carried counted gathered lifted opened folded followed measured repaired "
    "waited noticed remembered arranged"
).split()

# --------------------------------------------------------------------------
# The generator registry
# --------------------------------------------------------------------------


@dataclass
class Spec:
    """One registered generator: the file it makes and the function that makes it."""
    name: str            # the file name, which also names the hazard
    fmt: str             # a short format word for the manifest ("epub", "docx", ...)
    hazard: str          # one sentence saying what is nasty about the file
    large_only: bool     # True when only `--large` writes this file
    fn: object           # fn(rng) -> (bytes, expected_dict)


@dataclass
class Entry:
    """A generated file, ready to be written and listed in the manifest."""
    name: str
    fmt: str
    hazard: str
    data: bytes
    expected: dict = field(default_factory=dict)


REGISTRY = []  # every Spec, in definition order


def generator(name, fmt, hazard, large_only=False):
    """Register the decorated function as the generator of file `name`.

    The function takes a `random.Random` and returns `(bytes, expected_dict)`.
    """
    def register(fn):
        REGISTRY.append(Spec(name, fmt, hazard, large_only, fn))
        return fn
    return register


def build_entries(seed, large):
    """Run every applicable generator and return the entries sorted by file name.

    Each generator gets its own `random.Random` seeded from the seed and the
    file name, so adding or changing one generator never shifts another's output.
    """
    entries = []
    for spec in REGISTRY:
        if spec.large_only and not large:
            continue
        rng = random.Random(f"{seed}:{spec.name}")
        data, expected = spec.fn(rng)
        entries.append(Entry(spec.name, spec.fmt, spec.hazard, data, expected))
    return sorted(entries, key=lambda e: e.name)


# What the generator deliberately does not make, and why (listed in the manifest).
SKIPPED = [
    {"what": "DAISY 2.02 and DAISY 3 books",
     "reason": "Valid DAISY needs SMIL timing and audio files that a small deterministic text generator cannot make honestly."},
    {"what": "scanned (image-only) PDFs",
     "reason": "They need embedded raster images, which this generator avoids to stay small and standard-library only."},
]

# --------------------------------------------------------------------------
# Filler text helpers
# --------------------------------------------------------------------------


def sentence(rng):
    """One filler sentence of 8 to 16 plain words."""
    words = [rng.choice(WORDS) for _ in range(rng.randint(8, 16))]
    return words[0].capitalize() + " " + " ".join(words[1:]) + "."


def paragraph(rng, sentences=None):
    """A filler paragraph of 3 to 5 sentences (or exactly `sentences`)."""
    count = sentences if sentences is not None else rng.randint(3, 5)
    return " ".join(sentence(rng) for _ in range(count))


def phrase(rng):
    """A two-word title-cased phrase for a heading."""
    return f"{rng.choice(WORDS).capitalize()} {rng.choice(WORDS).capitalize()}"


# --------------------------------------------------------------------------
# Zip helper (shared by EPUB and DOCX)
# --------------------------------------------------------------------------


def build_zip(parts, stored=()):
    """Return the bytes of a zip holding `parts`, a list of (name, bytes) in order.

    Entry order is exactly the list order and every timestamp is fixed, so equal
    input gives byte-identical output.  Names in `stored` are not compressed
    (an EPUB's `mimetype` must be stored); everything else is deflated.
    """
    import io
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, data in parts:
            info = zipfile.ZipInfo(name, date_time=FIXED_ZIP_TIME)
            info.compress_type = zipfile.ZIP_STORED if name in stored else zipfile.ZIP_DEFLATED
            info.create_system = 3          # fixed, so the platform never leaks into the bytes
            info.external_attr = 0o644 << 16
            archive.writestr(info, data)
    return buffer.getvalue()


XML_DECL = '<?xml version="1.0" encoding="UTF-8"?>\n'


def utf8(text):
    """Encode text as UTF-8 bytes."""
    return text.encode("utf-8")


# --------------------------------------------------------------------------
# EPUB building blocks
# --------------------------------------------------------------------------


@dataclass
class Section:
    """A heading with its paragraphs and sub-sections (a tree of h1..h4)."""
    level: int
    title: str
    anchor: str
    paragraphs: list
    children: list = field(default_factory=list)


# How many children a section of a given level gets: (min, max).
CHILD_RANGE = {1: (2, 3), 2: (1, 2), 3: (1, 1)}


def make_chapter(rng, number, max_level):
    """Build chapter `number` as a Section tree going down to heading level `max_level`."""
    def build(level, anchor):
        section = Section(level, phrase(rng), anchor, [paragraph(rng) for _ in range(rng.randint(1, 2))])
        if level < max_level:
            low, high = CHILD_RANGE[level]
            for index in range(1, rng.randint(low, high) + 1):
                section.children.append(build(level + 1, f"{anchor}-s{index}"))
        return section
    return build(1, f"c{number}")


def walk(section):
    """Yield a section and all of its descendants in document order."""
    yield section
    for child in section.children:
        yield from walk(child)


def count_headings(chapters):
    """Total number of headings in a list of chapter trees."""
    return sum(1 for chapter in chapters for _ in walk(chapter))


def render_section(section, before_heading=None):
    """Render a section tree as XHTML.  `before_heading(section)` may add markup before each heading."""
    pieces = []
    if before_heading:
        pieces.append(before_heading(section))
    pieces.append(f'<h{section.level} id="{section.anchor}">{escape(section.title)}</h{section.level}>')
    pieces.extend(f"<p>{escape(text)}</p>" for text in section.paragraphs)
    pieces.extend(render_section(child, before_heading) for child in section.children)
    return "\n".join(pieces)


XHTML11_DOCTYPE = ('<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" '
                   '"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n')


def xhtml11_doc(title, body):
    """A complete EPUB 2 (XHTML 1.1) content document."""
    return (XML_DECL + XHTML11_DOCTYPE
            + '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">\n'
            + f"<head><title>{escape(title)}</title></head>\n<body>\n{body}\n</body>\n</html>\n")


def xhtml5_doc(title, body):
    """A complete EPUB 3 (XHTML 5) content document with the epub namespace declared."""
    return (XML_DECL + "<!DOCTYPE html>\n"
            + '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" '
              'xml:lang="en" lang="en">\n'
            + f"<head><title>{escape(title)}</title></head>\n<body>\n{body}\n</body>\n</html>\n")


CONTAINER_XML = (XML_DECL
                 + '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
                   '  <rootfiles>\n'
                   '    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>\n'
                   '  </rootfiles>\n</container>\n')


def epub_zip(parts):
    """Zip EPUB parts with `mimetype` first and stored, then the container, then the rest."""
    mimetype = ("mimetype", b"application/epub+zip")
    container = ("META-INF/container.xml", utf8(CONTAINER_XML))
    return build_zip([mimetype, container] + list(parts), stored=("mimetype",))


def book_uuid(rng):
    """A deterministic version-4 style UUID URN drawn from `rng`."""
    return "urn:uuid:" + str(uuid.UUID(int=rng.getrandbits(128), version=4))


def ncx_points(section, filename, counter, max_depth):
    """Render one NCX navPoint (and its nested children down to `max_depth`)."""
    counter[0] += 1
    number = counter[0]  # playOrder follows document order, so number before recursing
    inner = "".join(ncx_points(child, filename, counter, max_depth)
                    for child in section.children if child.level <= max_depth)
    src = filename if section.level == 1 else f"{filename}#{section.anchor}"
    return (f'<navPoint id="np{number}" playOrder="{number}"><navLabel><text>{escape(section.title)}'
            f'</text></navLabel><content src="{src}"/>{inner}</navPoint>')


def nav_items(section, filename, max_depth):
    """Render one EPUB 3 nav `<li>` (and a nested `<ol>` of children down to `max_depth`)."""
    kids = [child for child in section.children if child.level <= max_depth]
    nested = ("<ol>" + "".join(nav_items(k, filename, max_depth) for k in kids) + "</ol>") if kids else ""
    src = filename if section.level == 1 else f"{filename}#{section.anchor}"
    return f'<li><a href="{src}">{escape(section.title)}</a>{nested}</li>'


# --------------------------------------------------------------------------
# EPUB files
# --------------------------------------------------------------------------


@generator("epub2-ncx-nested.epub", "epub",
           "EPUB 2 whose NCX nests navPoints three deep over chapters with h1 to h4 headings and in-page anchors.")
def gen_epub2_ncx_nested(rng):
    title, author, file_as = "The Tannery Ledger", "Odalys Vrettos", "Vrettos, Odalys"
    chapters = [make_chapter(rng, n, max_level=4) for n in range(1, 5)]
    files = [f"ch{n}.xhtml" for n in range(1, 5)]

    parts = []
    for index, (chapter, filename) in enumerate(zip(chapters, files)):
        # An in-page link to the first sub-section and a link into the next chapter.
        first_child = chapter.children[0].anchor
        links = f'<p>Jump to <a href="#{first_child}">the first section</a>'
        if index + 1 < len(files):
            links += f' or on to <a href="{files[index + 1]}#{chapters[index + 1].anchor}">the next chapter</a>'
        links += ".</p>"
        parts.append((f"OEBPS/{filename}", utf8(xhtml11_doc(chapter.title, render_section(chapter) + "\n" + links))))

    counter = [0]
    points = "".join(ncx_points(c, f, counter, max_depth=3) for c, f in zip(chapters, files))
    uid = book_uuid(rng)
    ncx = (XML_DECL + '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
           f'<head><meta name="dtb:uid" content="{uid}"/><meta name="dtb:depth" content="3"/>'
           '<meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head>\n'
           f"<docTitle><text>{escape(title)}</text></docTitle>\n<navMap>{points}</navMap>\n</ncx>\n")
    items = "".join(f'<item id="ch{n}" href="{f}" media-type="application/xhtml+xml"/>'
                    for n, f in enumerate(files, 1))
    spine = "".join(f'<itemref idref="ch{n}"/>' for n in range(1, 5))
    opf = (XML_DECL + '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">\n'
           '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">\n'
           f"<dc:title>{escape(title)}</dc:title>\n"
           f'<dc:creator opf:role="aut" opf:file-as="{file_as}">{author}</dc:creator>\n'
           f'<dc:language>en</dc:language>\n<dc:identifier id="bookid">{uid}</dc:identifier>\n</metadata>\n'
           f'<manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>{items}</manifest>\n'
           f'<spine toc="ncx">{spine}</spine>\n</package>\n')
    parts += [("OEBPS/toc.ncx", utf8(ncx)), ("OEBPS/content.opf", utf8(opf))]
    expected = {"title": title, "author": author, "headings": count_headings(chapters),
                "toc_entries": counter[0], "spine_items": len(files)}
    return epub_zip(parts), expected


def epub3_package(title, creators_xml, uid, manifest_items, spine_ids):
    """Render an EPUB 3 package document.

    `creators_xml` is the pre-rendered creator metadata, `manifest_items` a list
    of (id, href, media_type, properties) and `spine_ids` the reading order.
    """
    items = "".join(
        f'<item id="{i}" href="{h}" media-type="{m}"' + (f' properties="{p}"' if p else "") + "/>"
        for i, h, m, p in manifest_items)
    spine = "".join(f'<itemref idref="{i}"/>' for i in spine_ids)
    return (XML_DECL + '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
            'unique-identifier="bookid" xml:lang="en">\n'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">\n'
            f'<dc:identifier id="bookid">{uid}</dc:identifier>\n'
            f'<dc:title id="title1">{escape(title)}</dc:title>\n'
            '<meta refines="#title1" property="title-type">main</meta>\n'
            f"<dc:language>en</dc:language>\n{creators_xml}\n"
            '<meta property="dcterms:modified">2020-01-01T00:00:00Z</meta>\n</metadata>\n'
            f"<manifest>{items}</manifest>\n<spine>{spine}</spine>\n</package>\n")


XHTML_TYPE = "application/xhtml+xml"


@generator("epub3-nav-landmarks.epub", "epub",
           "EPUB 3 with a toc nav holding a hidden branch, landmarks, a page-list, dcterms:modified, "
           "and two creators whose roles use refines and opf:role with file-as.")
def gen_epub3_nav_landmarks(rng):
    title = "Salt & Iron: A Survey"
    chapters = [make_chapter(rng, n, max_level=3) for n in range(1, 4)]
    files = [f"ch{n}.xhtml" for n in range(1, 4)]
    pages = []  # (page id, file, label) for the page-list

    def pagebreak_factory(filename):
        """Return a callback that inserts an epub:type=pagebreak marker before each heading."""
        def before(section):
            number = len(pages) + 1
            pages.append((f"pg{number}", filename, str(number)))
            return f'<span epub:type="pagebreak" role="doc-pagebreak" id="pg{number}" title="{number}"/>'
        return before

    parts = []
    for chapter, filename in zip(chapters, files):
        body = render_section(chapter, pagebreak_factory(filename))
        parts.append((f"OEBPS/{filename}", utf8(xhtml5_doc(chapter.title, body))))
    parts.append(("OEBPS/titlepage.xhtml", utf8(xhtml5_doc(
        title, f"<h1>{escape(title)}</h1>\n<p>A survey in three chapters.</p>"))))

    toc_items = "".join(nav_items(c, f, max_depth=3) for c, f in zip(chapters, files))
    # A hidden branch: an extra entry whose nested list carries the hidden attribute.
    toc_items += ('<li><a href="titlepage.xhtml">Front matter</a>'
                  '<ol hidden=""><li><a href="titlepage.xhtml">Hidden: colophon</a></li></ol></li>')
    page_items = "".join(f'<li><a href="{f}#{i}">{label}</a></li>' for i, f, label in pages)
    nav = xhtml5_doc("Contents", (
        f'<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>{toc_items}</ol></nav>\n'
        '<nav epub:type="landmarks" hidden=""><h2>Guide</h2><ol>'
        '<li><a epub:type="titlepage" href="titlepage.xhtml">Title page</a></li>'
        '<li><a epub:type="toc" href="nav.xhtml#toc">Contents</a></li>'
        f'<li><a epub:type="bodymatter" href="{files[0]}">Start of the book</a></li></ol></nav>\n'
        f'<nav epub:type="page-list" hidden=""><h2>Pages</h2><ol>{page_items}</ol></nav>'))
    parts.append(("OEBPS/nav.xhtml", utf8(nav)))

    creators = (
        '<dc:creator id="creator1">Wilhelmina Okafor</dc:creator>\n'
        '<meta refines="#creator1" property="role" scheme="marc:relators">aut</meta>\n'
        '<meta refines="#creator1" property="file-as">Okafor, Wilhelmina</meta>\n'
        '<dc:creator id="creator2" opf:role="edt" opf:file-as="Szabo, Bartholomew">Bartholomew Szabo</dc:creator>')
    manifest = [("nav", "nav.xhtml", XHTML_TYPE, "nav"), ("title", "titlepage.xhtml", XHTML_TYPE, "")]
    manifest += [(f"ch{n}", f, XHTML_TYPE, "") for n, f in enumerate(files, 1)]
    opf = epub3_package(title, creators, book_uuid(rng), manifest, ["title"] + [f"ch{n}" for n in range(1, 4)])
    parts.append(("OEBPS/content.opf", utf8(opf)))
    expected = {"title": title, "author": "Wilhelmina Okafor",
                "authors": ["Wilhelmina Okafor", "Bartholomew Szabo"],
                "headings": count_headings(chapters) + 1,  # plus the title page's h1
                "pages": len(pages), "spine_items": 4}
    return epub_zip(parts), expected


def epub3_chapters_book(rng, title, author, chapter_count, nav_lists_all):
    """A plain EPUB 3 of `chapter_count` chapters (h1 and h2 headings).

    When `nav_lists_all` is False the nav lists only the first chapter although
    every chapter is in the spine.
    """
    chapters = [make_chapter(rng, n, max_level=2) for n in range(1, chapter_count + 1)]
    files = [f"ch{n}.xhtml" for n in range(1, chapter_count + 1)]
    parts = [(f"OEBPS/{f}", utf8(xhtml5_doc(c.title, render_section(c)))) for c, f in zip(chapters, files)]
    listed = list(zip(chapters, files)) if nav_lists_all else [(chapters[0], files[0])]
    toc_items = "".join(nav_items(c, f, max_depth=2) for c, f in listed)
    nav = xhtml5_doc("Contents", f'<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>{toc_items}</ol></nav>')
    parts.append(("OEBPS/nav.xhtml", utf8(nav)))
    creators = f'<dc:creator id="creator1">{author}</dc:creator>'
    manifest = [("nav", "nav.xhtml", XHTML_TYPE, "nav")]
    manifest += [(f"ch{n}", f, XHTML_TYPE, "") for n, f in enumerate(files, 1)]
    opf = epub3_package(title, creators, book_uuid(rng), manifest, [f"ch{n}" for n in range(1, chapter_count + 1)])
    parts.append(("OEBPS/content.opf", utf8(opf)))
    expected = {"title": title, "author": author, "headings": count_headings(chapters),
                "toc_entries": sum(1 for c, _ in listed for _ in walk(c)), "spine_items": chapter_count}
    return epub_zip(parts), expected


@generator("epub3-no-nav-spine-only.epub", "epub",
           "Valid EPUB 3 whose spine holds four chapters but whose nav lists only the first.")
def gen_epub3_no_nav_spine_only(rng):
    return epub3_chapters_book(rng, "The Cartographer's Almanac", "Tobias Lindqvist", 4, nav_lists_all=False)


@generator("epub3-forty-chapters.epub", "epub",
           "EPUB 3 with forty chapters and a complete nav, to exercise long tables of contents.",
           large_only=True)
def gen_epub3_forty_chapters(rng):
    return epub3_chapters_book(rng, "Forty Crossings", "Ingrid Vandersloot", 40, nav_lists_all=True)


@generator("epub2-latin-entities.epub", "epub",
           "EPUB 2 using named entities (eacute, nbsp, numeric dashes), curly quotes, a run of br tags, and a footnote link.")
def gen_epub2_latin_entities(rng):
    title, author = "Café Society", "Rosalind Achterberg"
    # Raw XHTML: the entities are deliberately NOT expanded, because XHTML 1.1 allows
    # them through its DTD and a strict XML parser without the DTD cannot resolve them.
    ch1 = (
        '<h1 id="top">Caf&eacute; Society &amp; the Na&iuml;ve Reader</h1>\n'
        "<p>She ordered a cr&egrave;me br&ucirc;l&eacute;e&nbsp;&nbsp;&nbsp;and waited.&#160;"
        "The sign read &#x201C;Closed&#x201D; &#x2014; or did it&hellip;</p>\n"
        "<p>Literal curly quotes: “double”, ‘single’, and it’s an apostrophe.</p>\n"
        "<p>Verse follows<br/><br/><br/>after three breaks<br/>and one more<br/></p>\n"
        '<h2 id="notes">Notes</h2>\n'
        '<p>The claim needs a source.<a href="#fn1" id="fnref1" class="noteref"><sup>1</sup></a> '
        'Another lives in <a href="ch2.xhtml#fn2">the next chapter</a>.</p>\n'
        '<p id="fn1">1. The source itself, &copy; 1923. <a href="#fnref1">Back to the text</a></p>')
    ch2 = (
        '<h1 id="second">Second Course</h1>\n'
        f"<p>{escape(paragraph(rng))}</p>\n"
        '<p id="fn2">2. A note that lives in chapter two. <a href="ch1.xhtml#fnref1">Back to chapter one</a></p>')
    uid = book_uuid(rng)
    ncx = (XML_DECL + '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
           f'<head><meta name="dtb:uid" content="{uid}"/></head>\n'
           f"<docTitle><text>{escape(title)}</text></docTitle>\n<navMap>"
           '<navPoint id="np1" playOrder="1"><navLabel><text>Café Society</text></navLabel>'
           '<content src="ch1.xhtml"/></navPoint>'
           '<navPoint id="np2" playOrder="2"><navLabel><text>Second Course</text></navLabel>'
           '<content src="ch2.xhtml"/></navPoint></navMap>\n</ncx>\n')
    opf = (XML_DECL + '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">\n'
           '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">\n'
           f"<dc:title>{title}</dc:title>\n<dc:creator opf:role=\"aut\">{author}</dc:creator>\n"
           f'<dc:language>fr</dc:language>\n<dc:identifier id="bookid">{uid}</dc:identifier>\n</metadata>\n'
           '<manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
           '<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>'
           '<item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/></manifest>\n'
           '<spine toc="ncx"><itemref idref="ch1"/><itemref idref="ch2"/></spine>\n</package>\n')
    parts = [("OEBPS/ch1.xhtml", utf8(xhtml11_doc(title, ch1))),
             ("OEBPS/ch2.xhtml", utf8(xhtml11_doc("Second Course", ch2))),
             ("OEBPS/toc.ncx", utf8(ncx)), ("OEBPS/content.opf", utf8(opf))]
    return epub_zip(parts), {"title": title, "author": author, "headings": 3, "toc_entries": 2, "spine_items": 2}


# --------------------------------------------------------------------------
# DOCX building blocks
# --------------------------------------------------------------------------

W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
CT_NS = "http://schemas.openxmlformats.org/package/2006/content-types"
DOC_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
WORD_CT = "application/vnd.openxmlformats-officedocument.wordprocessingml"


def w_text(text):
    """A `w:t` element that keeps its spaces."""
    return f'<w:t xml:space="preserve">{escape(text)}</w:t>'


def w_run(text="", inner=""):
    """A run holding `text` (if any) followed by raw run content such as `<w:tab/>`."""
    body = (w_text(text) if text else "") + inner
    return f"<w:r>{body}</w:r>"


def w_para(runs="", style=None, num=None, outline=None):
    """A paragraph.  `num` is (numId, ilvl); `outline` is a direct outline level 0..9."""
    props = ""
    if style:
        props += f'<w:pStyle w:val="{style}"/>'
    if num:
        props += f'<w:numPr><w:ilvl w:val="{num[1]}"/><w:numId w:val="{num[0]}"/></w:numPr>'
    if outline is not None:
        props += f'<w:outlineLvl w:val="{outline}"/>'
    ppr = f"<w:pPr>{props}</w:pPr>" if props else ""
    return f"<w:p>{ppr}{runs}</w:p>"


def w_cell(text, width, span=None, vmerge=None):
    """A table cell.  `span` merges columns; `vmerge` is "restart" or "continue" for row merges."""
    props = f'<w:tcW w:w="{width}" w:type="dxa"/>'
    if span:
        props += f'<w:gridSpan w:val="{span}"/>'
    if vmerge == "restart":
        props += '<w:vMerge w:val="restart"/>'
    elif vmerge == "continue":
        props += "<w:vMerge/>"
    return f"<w:tc><w:tcPr>{props}</w:tcPr>{w_para(w_run(text) if text else '')}</w:tc>"


def w_row(cells, header=False):
    """A table row; `header=True` marks it as a repeating header row."""
    props = "<w:trPr><w:tblHeader/></w:trPr>" if header else ""
    return f"<w:tr>{props}{''.join(cells)}</w:tr>"


def document_xml(body):
    """Wrap body markup in a complete `w:document` with a section properties block."""
    return (XML_DECL + f'<w:document xmlns:w="{W_NS}" xmlns:r="{R_NS}"><w:body>{body}'
            '<w:sectPr><w:pgSz w:w="12240" w:h="15840"/>'
            '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" '
            'w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>')


def core_xml(title, creator):
    """The `docProps/core.xml` part with a title and a creator."""
    return (XML_DECL + '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
            'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
            f"<dc:title>{escape(title)}</dc:title><dc:creator>{escape(creator)}</dc:creator>"
            '<dcterms:created xsi:type="dcterms:W3CDTF">2020-01-01T00:00:00Z</dcterms:created>'
            "</cp:coreProperties>")


def content_types(overrides):
    """A `[Content_Types].xml` with the usual defaults and one override per (partname, type)."""
    rows = "".join(f'<Override PartName="{p}" ContentType="{t}"/>' for p, t in overrides)
    return (XML_DECL + f'<Types xmlns="{CT_NS}">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            f'<Default Extension="xml" ContentType="application/xml"/>{rows}</Types>')


def relationships(rows):
    """A `.rels` part from (id, type-suffix-or-full-type, target, external?) rows."""
    out = ""
    for rid, rel_type, target, external in rows:
        mode = ' TargetMode="External"' if external else ""
        out += f'<Relationship Id="{rid}" Type="{rel_type}" Target="{escape(target)}"{mode}/>'
    return XML_DECL + f'<Relationships xmlns="{REL_NS}">{out}</Relationships>'


def heading_style_xml(level):
    """One Heading N style, with the outline level that Word gives it."""
    size = max(24 - 2 * level, 12)
    return (f'<w:style w:type="paragraph" w:styleId="Heading{level}"><w:name w:val="heading {level}"/>'
            f'<w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>'
            f'<w:pPr><w:keepNext/><w:outlineLvl w:val="{level - 1}"/></w:pPr>'
            f'<w:rPr><w:b/><w:sz w:val="{size * 2}"/></w:rPr></w:style>')


def styles_xml():
    """The styles part: Normal, Title, Heading 1 to 6, List Paragraph, Hyperlink, Table Grid."""
    styles = (
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
        '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>'
        '<w:qFormat/><w:rPr><w:sz w:val="56"/></w:rPr></w:style>'
        + "".join(heading_style_xml(n) for n in range(1, 7))
        + '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/>'
          '<w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="720"/></w:pPr></w:style>'
          '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>'
          '<w:rPr><w:u w:val="single"/></w:rPr></w:style>'
          '<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/>'
          '<w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4"/><w:left w:val="single" w:sz="4"/>'
          '<w:bottom w:val="single" w:sz="4"/><w:right w:val="single" w:sz="4"/>'
          '<w:insideH w:val="single" w:sz="4"/><w:insideV w:val="single" w:sz="4"/></w:tblBorders></w:tblPr></w:style>')
    return XML_DECL + f'<w:styles xmlns:w="{W_NS}">{styles}</w:styles>'


def numbering_xml():
    """Numbering: numId 1 is a three-level bullet list, numId 2 a three-level numbered list."""
    def abstract(abstract_id, formats):
        levels = "".join(
            f'<w:lvl w:ilvl="{i}"><w:start w:val="1"/><w:numFmt w:val="{fmt}"/>'
            f'<w:lvlText w:val="{text}"/><w:lvlJc w:val="left"/>'
            f'<w:pPr><w:ind w:left="{720 * (i + 1)}" w:hanging="360"/></w:pPr></w:lvl>'
            for i, (fmt, text) in enumerate(formats))
        return f'<w:abstractNum w:abstractNumId="{abstract_id}">{levels}</w:abstractNum>'
    bullets = abstract(0, [("bullet", "•"), ("bullet", "o"), ("bullet", "▪")])
    numbers = abstract(1, [("decimal", "%1."), ("lowerLetter", "%2)"), ("lowerRoman", "%3.")])
    nums = ('<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
            '<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>')
    return XML_DECL + f'<w:numbering xmlns:w="{W_NS}">{bullets}{numbers}{nums}</w:numbering>'


def docx_zip(parts):
    """Zip DOCX parts in a fixed order, `[Content_Types].xml` first."""
    return build_zip(parts)


@generator("docx-headings-lists-tables.docx", "docx",
           "DOCX with Title, Heading 1 to 6, direct outline levels (including 9, meaning body text), "
           "three-deep bullet and numbered lists, a table with header rows and merged cells, a hyperlink, "
           "tabs, soft breaks, empty paragraphs, and core properties.")
def gen_docx_headings_lists_tables(rng):
    title, creator = "Harvest Ledger", "Ignatius Delacroix-Bauer"
    body = [w_para(w_run(title), style="Title"),
            w_para(w_run(paragraph(rng)))]
    headings = 0

    # Heading 1 to 6, each followed by a body paragraph; the first carries a bookmark.
    for level in range(1, 7):
        text = f"Heading level {level}: {phrase(rng)}"
        runs = w_run(text)
        if level == 1:
            runs = '<w:bookmarkStart w:id="0" w:name="top"/>' + runs + '<w:bookmarkEnd w:id="0"/>'
        body.append(w_para(runs, style=f"Heading{level}"))
        body.append(w_para(w_run(paragraph(rng, 2))))
        headings += 1

    # Direct outline levels on Normal paragraphs: 0 and 1 are headings, 9 means body text.
    for level, text in ((1, "Outline level two on a Normal paragraph"),
                        (0, "Outline level one on a Normal paragraph"),
                        (9, "Outline level nine means no outline level, so this is body text")):
        body.append(w_para(w_run(text), outline=level))
        if level != 9:
            headings += 1

    # Lists three levels deep (numId 1 bullets, numId 2 numbers).
    for num_id, label in ((1, "Bullet"), (2, "Numbered")):
        body.append(w_para(w_run(f"{label} list follows:")))
        for ilvl in (0, 1, 2, 1, 0):
            body.append(w_para(w_run(f"{label} item at depth {ilvl + 1}"), style="ListParagraph", num=(num_id, ilvl)))

    # A table: two repeating header rows (merged across and down), data rows, and a full-width row.
    rows = [
        w_row([w_cell("Fruit", 3000, vmerge="restart"), w_cell("Weight in crates", 6000, span=2)], header=True),
        w_row([w_cell("", 3000, vmerge="continue"), w_cell("Spring", 3000), w_cell("Autumn", 3000)], header=True),
        w_row([w_cell("Apples", 3000), w_cell("12", 3000), w_cell("15", 3000)]),
        w_row([w_cell("Pears", 3000), w_cell("8", 3000), w_cell("9", 3000)]),
        w_row([w_cell("All fruit combined: 44 crates", 9000, span=3)]),
    ]
    body.append(w_para(w_run("A table follows:")))
    body.append('<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="9000" w:type="dxa"/></w:tblPr>'
                '<w:tblGrid><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/><w:gridCol w:w="3000"/></w:tblGrid>'
                + "".join(rows) + "</w:tbl>")

    # Hyperlinks (one external through a relationship, one internal to the bookmark).
    body.append(w_para(
        w_run("Read more at ")
        + '<w:hyperlink r:id="rId3"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr>'
          + w_text("the example site") + "</w:r></w:hyperlink>"
        + w_run(" or ")
        + '<w:hyperlink w:anchor="top"><w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr>'
          + w_text("jump back to the top") + "</w:r></w:hyperlink>" + w_run(".")))

    # Tabs, soft line breaks, and empty paragraphs.
    body.append(w_para(w_run("Name", "<w:tab/>") + w_run("Quantity", "<w:tab/>") + w_run("Price")))
    body.append(w_para(w_run("First line", "<w:br/>") + w_run("Second line", "<w:br/>") + w_run("Third line")))
    body += [w_para(), w_para(), w_para(w_run("   ")), w_para(w_run("The last real paragraph."))]

    parts = [
        ("[Content_Types].xml", utf8(content_types([
            ("/word/document.xml", WORD_CT + ".document.main+xml"),
            ("/word/styles.xml", WORD_CT + ".styles+xml"),
            ("/word/numbering.xml", WORD_CT + ".numbering+xml"),
            ("/docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml")]))),
        ("_rels/.rels", utf8(relationships([
            ("rId1", DOC_REL + "/officeDocument", "word/document.xml", False),
            ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties",
             "docProps/core.xml", False)]))),
        ("word/_rels/document.xml.rels", utf8(relationships([
            ("rId1", DOC_REL + "/styles", "styles.xml", False),
            ("rId2", DOC_REL + "/numbering", "numbering.xml", False),
            ("rId3", DOC_REL + "/hyperlink", "https://example.org/harvest?a=1&b=2", True)]))),
        ("word/document.xml", utf8(document_xml("".join(body)))),
        ("word/styles.xml", utf8(styles_xml())),
        ("word/numbering.xml", utf8(numbering_xml())),
        ("docProps/core.xml", utf8(core_xml(title, creator))),
    ]
    expected = {"title": title, "author": creator, "headings": headings,
                "headings_basis": "Heading 1 to 6 paragraphs plus Normal paragraphs with outline level 0 to 8; the Title paragraph and outline level 9 are body"}
    return docx_zip(parts), expected


@generator("docx-no-styles.docx", "docx",
           "DOCX of plain paragraphs only, with no styles part and no relationships beyond the main document.")
def gen_docx_no_styles(rng):
    body = "".join(w_para(w_run(paragraph(rng))) for _ in range(6))
    parts = [
        ("[Content_Types].xml", utf8(content_types([("/word/document.xml", WORD_CT + ".document.main+xml")]))),
        ("_rels/.rels", utf8(relationships([("rId1", DOC_REL + "/officeDocument", "word/document.xml", False)]))),
        ("word/document.xml", utf8(document_xml(body))),
    ]
    return docx_zip(parts), {"title": None, "author": None, "headings": 0}


# --------------------------------------------------------------------------
# Markdown files
# --------------------------------------------------------------------------


def count_markdown_headings(text):
    """Count ATX and setext headings in Markdown, ignoring anything inside code fences.

    Lines are split on "\\n" only (Python's splitlines would also split on the
    Unicode separators that the unicode file carries on purpose).
    """
    count, fence, previous_blank = 0, None, True
    lines = text.split("\n")
    for index, line in enumerate(lines):
        stripped = line.lstrip(" ")
        indent = len(line) - len(stripped)
        marker = re.match(r"(`{3,}|~{3,})", stripped) if indent <= 3 else None
        if fence:
            # Inside a fence only a closing fence of the same character matters.
            if marker and marker.group(1)[0] == fence[0] and len(marker.group(1)) >= len(fence):
                fence = None
            previous_blank = False
            continue
        if marker:
            fence = marker.group(1)
            previous_blank = False
            continue
        if indent <= 3 and re.match(r"#{1,6}(\s|$)", stripped):
            count += 1
        elif (previous_blank and indent <= 3 and stripped and not re.match(r"[#>|`~*+\-<\[]|\d+[.)]\s", stripped)
              and index + 1 < len(lines) and re.fullmatch(r" {0,3}(=+|-+)\s*", lines[index + 1])):
            count += 1
        previous_blank = not line.strip()
    return count


@generator("markdown-feature-soup.md", "markdown",
           "Markdown using setext and ATX headings 1 to 6, aligned tables, fenced and indented code with "
           "heading-like lines inside, nested lists, block quotes, footnotes, link references, inline HTML and hard breaks.")
def gen_markdown_feature_soup(rng):
    def row(*cells):
        """A table row from its cells."""
        return "| " + " | ".join(str(c) for c in cells) + " |"

    lines = [
        "Setext Level One Heading", "========================", "",
        paragraph(rng), "",
        "Setext Level Two Heading", "------------------------", "",
        "# ATX Level One", "", "## ATX Level Two", "", "### ATX Level Three", "",
        "#### ATX Level Four", "", "##### ATX Level Five", "", "###### ATX Level Six", "",
        "## Closed ATX Heading ##", "",
        "## Heading with *emphasis* and a [link](https://example.org/heading)", "",
        "### Tables", "",
        row("Left aligned", "Centered", "Right aligned"),
        "|:-------------|:--------:|--------------:|",
        row(phrase(rng), phrase(rng), rng.randint(10, 9999)),
        row(phrase(rng), phrase(rng), rng.randint(10, 9999)),
        row("A pipe \\| inside a cell", "`code | pipe`", rng.randint(10, 9999)),
        "", "A table without outer pipes:", "",
        "Item | Quantity", "--- | ---",
        f"{phrase(rng)} | {rng.randint(1, 99)}", f"{phrase(rng)} | {rng.randint(1, 99)}", "",
        "### Code", "",
        "```python", "# This line starts with a hash but is code, not a heading", "def harbor():",
        "    return 'ledger'", "```", "",
        "~~~text", "A tilde fence with a setext-looking pair of lines", "==================", "~~~", "",
        "    An indented code block", "    # also not a heading", "",
        "### Lists", "",
        "- Top level bullet", "  - Nested bullet", "    - Third level bullet", "      1. Numbered inside a bullet",
        "      2. Second numbered item", "  - Back at the second level", "- Another top level bullet",
        "", "  A paragraph continuing the last bullet.", "",
        "1. First step", "2. Second step", "   - A bullet under a step", "3. Third step", "",
        "- [x] A finished task", "- [ ] An open task", "",
        "### Quotes", "",
        "> A block quote opens here.", ">", "> > A quote nested inside the quote.", "> > > And one more level.", ">",
        "> - A list inside a quote", "> - with two items", "",
        "### Notes and links", "",
        "A sentence with a footnote.[^1] Another with a named one.[^second]", "",
        "[^1]: The first footnote.", "[^second]: The second footnote,", "    continued on an indented line.", "",
        "See the [documentation][docs], the [guide][], or <https://example.org/autolink>.", "",
        "[docs]: https://example.org/docs \"Documentation\"", "[guide]: https://example.org/guide", "",
        "### Inline markup", "",
        "Text with <kbd>Ctrl</kbd> and <span style=\"color: red\">inline HTML</span>, **bold**, *italic*, "
        "~~struck~~, ``code with a `backtick` inside`` and an escaped \\*asterisk\\*. Also &copy; and an image "
        "![A diagram of a harbor](harbor.png \"Harbor\").", "",
        "<details>", "<summary>An HTML block</summary>", "", "Content inside the details block.", "", "</details>", "",
        "<!-- A comment that should not be read aloud. -->", "",
        "A hard break with two spaces  ", "continues on the next line,\\", "and again after a backslash.", "",
        "* * *", "",
        phrase(rng) + ": " + paragraph(rng, 2), "",
    ]
    text = "\n".join(lines)
    expected = {"title": "Setext Level One Heading", "headings": count_markdown_headings(text)}
    return utf8(text), expected


@generator("markdown-very-long.md", "markdown",
           "Five megabytes of Markdown: 400 sections of repeated structure with a table every 20 sections.",
           large_only=True)
def gen_markdown_very_long(rng):
    section_bytes = 12_400  # 400 sections of about this size give about 5.2 MB
    pieces = ["# A Very Long Document\n\n" + paragraph(rng) + "\n"]
    for number in range(1, 401):
        section = [f"\n## Section {number}: {phrase(rng)}\n"]
        while sum(len(p) for p in section) < section_bytes:
            section.append("\n" + paragraph(rng) + "\n")
        section.append(f"\n### Details of section {number}\n")
        section.append("".join(f"\n- {sentence(rng)}" for _ in range(4)) + "\n")
        if number % 20 == 0:
            section.append("\n| Measure | Value | Unit |\n|:--|--:|:--|\n")
            section.append("".join(f"| {phrase(rng)} | {rng.randint(1, 9999)} | {rng.choice(WORDS)} |\n" for _ in range(5)))
        pieces.extend(section)
    text = "".join(pieces)
    return utf8(text), {"title": "A Very Long Document", "headings": count_markdown_headings(text), "sections": 400}


# Hazard lines for the Unicode file, grouped under a heading.  Invisible characters use escapes.
UNICODE_GROUPS = [
    ("Scripts and directions", [
        ("Arabic, right to left", "مرحبا بالعالم، هذا اختبار للقراءة."),
        ("Hebrew, right to left", "שלום עולם, זהו מבחן קריאה."),
        ("Mixed direction", "The word שלום means peace and مرحبا means hello, inside one English sentence 123."),
        ("Chinese", "你好，世界。这是一个朗读测试。"),
        ("Japanese", "こんにちは、世界。これは読み上げのテストです。漢字とひらがなとカタカナ。"),
        ("Korean", "안녕하세요 세계. 이것은 읽기 시험입니다."),
        ("Thai, no spaces between words", "สวัสดีชาวโลกนี่คือการทดสอบการอ่านออกเสียง"),
        ("Devanagari", "नमस्ते दुनिया, यह पढ़ने का एक परीक्षण है।"),
    ]),
    ("Emoji and flags", [
        ("Emoji with skin tone modifiers", "\U0001F44D\U0001F3FB \U0001F44D\U0001F3FD \U0001F44D\U0001F3FF"),
        ("Emoji joined with zero width joiners", "\U0001F468‍\U0001F469‍\U0001F467‍\U0001F466 and \U0001F9D1‍\U0001F4BB"),
        ("Rainbow flag, a joiner sequence", "\U0001F3F3️‍\U0001F308"),
        ("Flags from regional indicators", "\U0001F1E8\U0001F1E6 \U0001F1EF\U0001F1F5 \U0001F1E7\U0001F1F7"),
        ("Variation selectors", "☹︎ text style and ☹️ emoji style, plus an ideographic variant 邊\U000E0100"),
    ]),
    ("Normalization and astral characters", [
        ("Decomposed accents", "café naïve niño"),
        ("Precomposed accents", "café naïve niño"),
        ("A stack of combining marks", "á̂̃̄ after four marks"),
        ("Astral plane letters", "\U0001D4D0\U0001D4D1\U0001D4D2 and \U00020BB7 and \U00010348"),
        ("Full width and half width forms", "ＡＢＣ １２３ ｱｲｳ"),
        ("Ligature characters", "ﬁ ﬂ ﬃ"),
    ]),
    ("Invisible and control characters", [
        ("Soft hyphens", "inter­na­tion­al­i­za­tion"),
        ("No-break spaces", "10 000 km and Mr. Ferreira"),
        ("Zero width space and non-joiner", "zero​width and non‌joiner"),
        ("Line and paragraph separators", "first second third"),
        ("A stray byte order mark mid-text", "before﻿after"),
        ("Bidirectional override", "plain ‮guarded text‬ plain again"),
        ("Bidirectional isolates", "left ⁧right to left⁩ and back ⁦left to right⁩"),
    ]),
]


@generator("unicode-heavy.md", "markdown",
           "Markdown with right-to-left scripts, CJK, Thai, Devanagari, emoji joiner sequences, decomposed accents, "
           "astral characters, soft hyphens, line separators, a mid-text BOM and bidirectional controls, one per labelled line.")
def gen_unicode_heavy(rng):
    lines = ["# Unicode Hazards", "", "Every line below carries one hazard, named before the colon.", ""]
    for group, hazards in UNICODE_GROUPS:
        lines += [f"## {group}", ""]
        for label, content in hazards:
            lines += [f"{label}: {content}", ""]
    text = "\n".join(lines)
    return utf8(text), {"title": "Unicode Hazards", "headings": count_markdown_headings(text),
                        "hazard_lines": sum(len(h) for _, h in UNICODE_GROUPS)}


# --------------------------------------------------------------------------
# Plain text files
# --------------------------------------------------------------------------

# The one short passage written in every encoding and line-ending style.
# It uses only characters that Latin-1 can hold, so every encoding carries it exactly.
PASSAGE_LINES = [
    "The Café at the Corner",
    "",
    "Renée carried a naïve plan and a small suitcase to the café, where the waiter said "
    "¡Buenos días! and brought her a jalapeño tart for £12.",
    "",
    "The lamp stayed lit until closing, and nobody asked her to leave.",
]
# Extra lines for the Unicode encodings, which can hold what Latin-1 cannot.
UNICODE_EXTRA = ["", "Beyond Latin-1: Привет, 世界, and a snowman ☃."]
# Extra lines for Windows-1252, whose 0x80 to 0x9F bytes Latin-1 treats as control codes.
WIN1252_EXTRA = ["", "Windows-1252 only: “curly quotes”, ‘single’, a dash — the euro €, an ellipsis… and a bullet •."]


@dataclass
class TextVariant:
    """How one plain text file is encoded: codec, line ending, BOM bytes, and extra lines."""
    codec: str
    newline: str = "\n"
    bom: bytes = b""
    extra: tuple = ()

    def lines(self):
        """The passage lines this file holds."""
        return PASSAGE_LINES + list(self.extra)

    def encode(self):
        """The file's bytes: BOM, then the lines joined and terminated by the line ending."""
        text = self.newline.join(self.lines()) + self.newline
        return self.bom + text.encode(self.codec)


TEXT_VARIANTS = {
    "text-utf8.txt": (TextVariant("utf-8", extra=UNICODE_EXTRA),
                      "Plain UTF-8 text with no byte order mark, including Cyrillic, Chinese and a snowman."),
    "text-utf16le-bom.txt": (TextVariant("utf-16-le", bom=b"\xff\xfe", extra=UNICODE_EXTRA),
                             "UTF-16 little-endian text that begins with a byte order mark."),
    "text-utf16be-bom.txt": (TextVariant("utf-16-be", bom=b"\xfe\xff", extra=UNICODE_EXTRA),
                             "UTF-16 big-endian text that begins with a byte order mark."),
    "text-latin1.txt": (TextVariant("latin-1"),
                        "ISO 8859-1 text whose accented bytes are not valid UTF-8."),
    "text-windows1252.txt": (TextVariant("cp1252", extra=WIN1252_EXTRA),
                             "Windows-1252 text with curly quotes, a dash and a euro sign in the 0x80 to 0x9F bytes."),
    "text-crlf.txt": (TextVariant("utf-8", newline="\r\n"),
                      "UTF-8 text whose every line ends in carriage return and line feed."),
    "text-cr-only.txt": (TextVariant("utf-8", newline="\r"),
                         "UTF-8 text whose lines end in a bare carriage return, as on classic Mac OS."),
}


def register_text_variant(name, variant, hazard):
    """Register the generator of one TEXT_VARIANTS file."""
    @generator(name, "text", hazard)
    def make(rng):
        return variant.encode(), {"title": PASSAGE_LINES[0], "encoding": variant.codec,
                                  "line_ending": {"\n": "LF", "\r\n": "CRLF", "\r": "CR"}[variant.newline],
                                  "lines": len(variant.lines())}
    return make


for _name, (_variant, _hazard) in TEXT_VARIANTS.items():
    register_text_variant(_name, _variant, _hazard)


# Three pages separated by form feeds, each ending in a page-number footer.
FORM_FEED_PAGES = [
    ["Page one opens here.", "The text runs on for a few short lines", "before the page ends.", "- 1 -"],
    ["Page two begins after a form feed.", "It has its own two lines.", "- 2 -"],
    ["Page three is the last one.", "- 3 -"],
]


@generator("text-form-feeds.txt", "text",
           "UTF-8 text whose pages are separated by form feed characters (U+000C) and end in page-number footers.")
def gen_text_form_feeds(rng):
    pages = ["\n".join(page) + "\n" for page in FORM_FEED_PAGES]
    return utf8("\f".join(pages)), {"title": FORM_FEED_PAGES[0][0], "pages": len(pages)}


# Lines that are real headings, and all-caps lines that merely look like headings.
CAPS_HEADINGS = ["THE HARBOR LEDGER", "CHAPTER ONE: THE ARRIVAL", "CHAPTER TWO: THE CROSSING", "EPILOGUE"]
CAPS_DECOYS = ["WARNING: DO NOT OPEN THE CELLAR DOOR!", "NASA"]


@generator("text-all-caps-headings.txt", "text",
           "UTF-8 text whose headings are all-caps lines, with all-caps decoys (a shouted warning, an acronym) that are not headings.")
def gen_text_all_caps_headings(rng):
    lines = [CAPS_HEADINGS[0], "", paragraph(rng, 2), "", CAPS_HEADINGS[1], "", paragraph(rng, 3), "",
             CAPS_DECOYS[0], "", paragraph(rng, 2), "", CAPS_HEADINGS[2], "", paragraph(rng, 2), "",
             CAPS_DECOYS[1], "", "That acronym alone on its line was not a heading either.", "",
             CAPS_HEADINGS[3], "", paragraph(rng, 2), ""]
    return utf8("\n".join(lines) + "\n"), {"title": CAPS_HEADINGS[0], "headings": len(CAPS_HEADINGS),
                                           "decoys": CAPS_DECOYS}


@generator("text-one-long-line.txt", "text",
           "Three megabytes of UTF-8 text on a single line with no line ending at all.",
           large_only=True)
def gen_text_one_long_line(rng):
    target = 3 * 1024 * 1024
    pieces, size = [], 0
    while size < target:
        piece = sentence(rng)
        pieces.append(piece)
        size += len(piece) + 1
    return utf8(" ".join(pieces)), {"title": None, "lines": 1}


# --------------------------------------------------------------------------
# HTML file
# --------------------------------------------------------------------------

# The page is encoded as Windows-1252 when written: its curly quotes, dash, euro sign and bullet use bytes 0x80 to 0x9F.
HTML_SOUP = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="windows-1252">
<title>Nested Soup</title>
<style>
  body::after { content: "STYLE TEXT MUST NOT BE READ"; }
</style>
<script>
  var hidden = "SCRIPT TEXT MUST NOT BE READ";
  if (1 < 2 && 3 > 2) { document.write("<h1>A heading made by script</h1>"); }
</script>
</head>
<body>
<h1>Nested Soup</h1>
<div class="outer"><section><div><article>
<h2>Deeply nested heading</h2>
<p>Paragraph without a closing tag
<p>Another paragraph ended by the next one, with an entity &amp; a numeric one &#8212; and &lt;angle brackets&gt;.
<h3>Third level</h3>
<ul><li>First item without a closing tag<li>Second item<ul><li>Nested item</ul></ul>
</article></div></section></div>
<table border="1">
<caption>Outer table</caption>
<tr><th>Name<th>Detail
<tr><td>Outer cell<td><table><tr><td>Inner table cell</table>
</table>
<h4>Fourth level</h4>
<pre>
    Preformatted text keeps   its spaces
      and its indentation, even &lt;tags&gt;.
</pre>
<p>Spaces:&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;end of the run.</p>
<p>First paragraph made with breaks<br><br>Second paragraph made with breaks<br><br>Third paragraph made with breaks</p>
<h5>Fifth level</h5>
<p>Windows-1252 characters: “double” ‘single’ a dash — the euro € an ellipsis… a bullet • and café.</p>
<!-- A comment that must not be read. -->
<h6>Sixth level</h6>
<p>The end.</p>
</body>
</html>
"""


@generator("html-nested-soup.html", "html",
           "HTML 5 with deeply nested sections, nested tables, unclosed tags, pre, script and style text that must not be read, "
           "nbsp runs, double-br paragraphs, h1 to h6, and a windows-1252 charset with matching bytes.")
def gen_html_nested_soup(rng):
    headings = len(re.findall(r"<h[1-6][ >]", HTML_SOUP))
    # The script writes an h1 in a string; it is not a heading of the document.
    headings -= HTML_SOUP.count('document.write("<h1>')
    return HTML_SOUP.encode("cp1252"), {"title": "Nested Soup", "headings": headings, "charset": "windows-1252"}


# --------------------------------------------------------------------------
# Writing the corpus
# --------------------------------------------------------------------------


class CorpusError(Exception):
    """A refusal or failure that main() reports as one plain line."""


def previous_owned_files(out):
    """Check that `out` may be written to and return the names a previous run left there.

    A missing or empty folder is fine.  A folder with anything in it must hold
    our manifest and nothing the manifest does not list; otherwise we refuse, so
    a script run can never replace someone else's files.
    """
    if not out.exists():
        return set()
    if not out.is_dir():
        raise CorpusError(f"{out} exists and is not a folder")
    present = {item.name for item in out.iterdir()}
    if not present:
        return set()
    manifest = out / MANIFEST_NAME
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
        owned = {item["name"] for item in data["files"]}
        is_ours = data.get("generator") == GENERATOR_ID
    except (OSError, ValueError, KeyError, TypeError):
        is_ours, owned = False, set()
    if not is_ours:
        raise CorpusError(f"refusing {out}: it holds files but no {MANIFEST_NAME} from this script")
    foreign = sorted(present - owned - {MANIFEST_NAME})
    if foreign:
        raise CorpusError(f"refusing {out}: it holds files this script did not write, such as {foreign[0]}")
    return owned


def manifest_for(entries, seed, large):
    """Build the manifest dictionary for the entries just generated."""
    return {
        "generator": GENERATOR_ID,
        "seed": seed,
        "large": large,
        "files": [{"name": e.name, "format": e.fmt, "bytes": len(e.data),
                   "sha256": hashlib.sha256(e.data).hexdigest(),
                   "hazard": e.hazard, "expected": e.expected} for e in entries],
        "skipped": SKIPPED,
    }


def write_corpus(out, seed, large, say=print):
    """Generate the corpus into `out`; call `say(line)` for each file written.

    Returns the list of entries.  Files from an earlier run that this run does
    not produce (for example the large ones) are removed.
    """
    out = Path(out)
    previous = previous_owned_files(out)
    out.mkdir(parents=True, exist_ok=True)
    entries = build_entries(seed, large)
    names = {e.name for e in entries}
    for stale in sorted(previous - names):
        (out / stale).unlink(missing_ok=True)
    for entry in entries:
        (out / entry.name).write_bytes(entry.data)
        say(f"{entry.name}: {len(entry.data)} bytes")
    manifest_bytes = (json.dumps(manifest_for(entries, seed, large), indent=2) + "\n").encode("utf-8")
    (out / MANIFEST_NAME).write_bytes(manifest_bytes)
    say(f"{MANIFEST_NAME}: {len(manifest_bytes)} bytes")
    say(f"wrote {len(entries) + 1} files to {out}")
    return entries


# --------------------------------------------------------------------------
# Selftest
# --------------------------------------------------------------------------


class Tester:
    """Counts checks and collects failure lines."""

    def __init__(self):
        self.checks = 0
        self.failures = []

    def check(self, condition, message):
        """Record one check; `message` is printed only when it fails."""
        self.checks += 1
        if not condition:
            self.failures.append(message)


def parse_xml(data):
    """Parse XML/XHTML bytes, first expanding HTML named entities (XHTML 1.1 gets them from its DTD)."""
    keep = {"amp", "lt", "gt", "quot", "apos"}

    def expand(match):
        name = match.group(1)
        if name in keep or name not in name2codepoint:
            return match.group(0)
        return f"&#{name2codepoint[name]};"

    text = re.sub(r"&([A-Za-z][A-Za-z0-9]*);", expand, data.decode("utf-8"))
    return ET.fromstring(text.encode("utf-8"))


def local(tag):
    """The local name of an ElementTree tag."""
    return tag.rsplit("}", 1)[-1]


def element_ids(root):
    """All id / xml:id / name attributes in a parsed document (anchor targets)."""
    ids = set()
    for node in root.iter():
        for key, value in node.attrib.items():
            if local(key) in ("id", "name") and node.tag != "meta":
                ids.add(value)
    return ids


def open_zip(t, name, data):
    """Open `data` as a zip, check its entries are unique and carry the fixed time; return the ZipFile or None."""
    import io
    try:
        archive = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as error:
        t.check(False, f"{name}: not a zip ({error})")
        return None
    names = archive.namelist()
    t.check(len(names) == len(set(names)), f"{name}: duplicate zip entries")
    t.check(all(i.date_time == FIXED_ZIP_TIME for i in archive.infolist()), f"{name}: zip timestamps are not fixed")
    t.check(archive.testzip() is None, f"{name}: a zip entry fails its CRC")
    return archive


def check_xml_parts(t, name, archive, suffixes):
    """Parse every part ending in one of `suffixes`; return {part name: root element}."""
    roots = {}
    for part in archive.namelist():
        if part.endswith(suffixes):
            try:
                roots[part] = parse_xml(archive.read(part))
                t.check(True, "")
            except (ET.ParseError, UnicodeDecodeError) as error:
                t.check(False, f"{name}: {part} does not parse ({error})")
    return roots


def resolve(base_part, href):
    """Resolve `href` (percent-decoded, fragment split off) against the part `base_part`."""
    path, _, fragment = unquote(href).partition("#")
    target = posixpath.normpath(posixpath.join(posixpath.dirname(base_part), path)) if path else base_part
    return target, fragment


def check_epub(t, name, data, expected):
    """Structural EPUB checks: mimetype, container, package, spine, parts, and navigation targets."""
    archive = open_zip(t, name, data)
    if archive is None:
        return
    first = archive.infolist()[0]
    t.check(first.filename == "mimetype", f"{name}: first entry is {first.filename}, not mimetype")
    t.check(first.compress_type == zipfile.ZIP_STORED, f"{name}: mimetype is compressed")
    t.check(archive.read("mimetype") == b"application/epub+zip", f"{name}: wrong mimetype content")
    roots = check_xml_parts(t, name, archive, (".xml", ".opf", ".ncx", ".xhtml"))

    container = roots.get("META-INF/container.xml")
    rootfile = next((n.attrib["full-path"] for n in container.iter() if local(n.tag) == "rootfile"), None) if container is not None else None
    t.check(rootfile in archive.namelist(), f"{name}: container.xml names a missing package {rootfile}")
    if rootfile not in roots:
        return
    package = roots[rootfile]
    manifest = {n.attrib["id"]: n.attrib["href"] for n in package.iter() if local(n.tag) == "item"}
    for item_id, href in manifest.items():
        target, _ = resolve(rootfile, href)
        t.check(target in archive.namelist(), f"{name}: manifest item {item_id} points at missing {target}")
    spine = [n.attrib["idref"] for n in package.iter() if local(n.tag) == "itemref"]
    t.check(bool(spine), f"{name}: empty spine")
    for idref in spine:
        t.check(idref in manifest, f"{name}: spine item {idref} is not in the manifest")
    if "spine_items" in expected:
        t.check(len(spine) == expected["spine_items"], f"{name}: spine has {len(spine)} items, manifest says {expected['spine_items']}")

    # Every navigation target (NCX content or nav anchors) must exist, with its fragment.
    ids_by_part = {part: element_ids(root) for part, root in roots.items()}
    nav_points = 0
    for part, root in roots.items():
        if part.endswith(".ncx"):
            hrefs = [n.attrib["src"] for n in root.iter() if local(n.tag) == "content"]
            nav_points += len(hrefs)
        elif part.endswith("nav.xhtml"):
            hrefs = [n.attrib["href"] for nav in root.iter() if local(nav.tag) == "nav"
                     and any(local(k) == "type" and v == "toc" for k, v in nav.attrib.items())
                     for n in nav.iter() if local(n.tag) == "a"]
            nav_points += len(hrefs)
        else:
            continue
        for href in hrefs:
            target, fragment = resolve(part, href)
            t.check(target in archive.namelist(), f"{name}: {part} links to missing {target}")
            if fragment and target in ids_by_part:
                t.check(fragment in ids_by_part[target], f"{name}: {part} links to missing anchor {target}#{fragment}")
    if "toc_entries" in expected:
        t.check(nav_points == expected["toc_entries"], f"{name}: {nav_points} toc entries, manifest says {expected['toc_entries']}")

    # Heading count over the spine documents must match the manifest.
    spine_parts = {resolve(rootfile, manifest[i])[0] for i in spine if i in manifest}
    found = sum(1 for part in spine_parts if part in roots
                for n in roots[part].iter() if re.fullmatch(r"h[1-6]", local(n.tag)))
    if "headings" in expected:
        t.check(found == expected["headings"], f"{name}: {found} headings found, manifest says {expected['headings']}")


def check_docx(t, name, data, expected):
    """Structural DOCX checks: parts parse, content types cover each part, relationship targets exist."""
    archive = open_zip(t, name, data)
    if archive is None:
        return
    parts = archive.namelist()
    t.check(parts[0] == "[Content_Types].xml", f"{name}: [Content_Types].xml is not first")
    roots = check_xml_parts(t, name, archive, (".xml", ".rels"))
    types = roots.get("[Content_Types].xml")
    if types is None:
        return
    defaults = {n.attrib["Extension"].lower() for n in types.iter() if local(n.tag) == "Default"}
    overrides = {n.attrib["PartName"] for n in types.iter() if local(n.tag) == "Override"}
    for part in parts:
        if part == "[Content_Types].xml":
            continue
        covered = ("/" + part) in overrides or part.rsplit(".", 1)[-1].lower() in defaults
        t.check(covered, f"{name}: {part} is not covered by [Content_Types].xml")
    for override in overrides:
        t.check(override.lstrip("/") in parts, f"{name}: content type override for missing part {override}")
    # Internal relationship targets must exist.
    for part, root in roots.items():
        if not part.endswith(".rels"):
            continue
        source_dir = posixpath.dirname(posixpath.dirname(part))  # the folder the rels file describes
        for rel in root.iter():
            if local(rel.tag) == "Relationship" and rel.attrib.get("TargetMode") != "External":
                target = posixpath.normpath(posixpath.join(source_dir, rel.attrib["Target"]))
                t.check(target in parts, f"{name}: {part} targets missing part {target}")
    document = roots.get("word/document.xml")
    t.check(document is not None and any(local(n.tag) == "body" for n in document.iter()),
            f"{name}: no word/document.xml body")
    if document is not None and "headings" in expected:
        found = count_docx_headings(document)
        t.check(found == expected["headings"], f"{name}: {found} headings found, manifest says {expected['headings']}")


def count_docx_headings(document):
    """Count Heading 1 to 6 paragraphs and Normal paragraphs with direct outline level 0 to 8."""
    count = 0
    for para in document.iter():
        if local(para.tag) != "p":
            continue
        style = outline = None
        for prop in para.iter():
            if local(prop.tag) == "pStyle":
                style = prop.attrib.get(f"{{{W_NS}}}val")
            elif local(prop.tag) == "outlineLvl":
                outline = int(prop.attrib.get(f"{{{W_NS}}}val"))
        if style and re.fullmatch(r"Heading[1-6]", style) or (outline is not None and outline <= 8):
            count += 1
    return count


# Code points that unicode-heavy.md must carry, named by hazard (an independent list from the generator's).
REQUIRED_CODE_POINTS = {
    "combining acute": 0x0301, "right-to-left override": 0x202E, "byte order mark": 0xFEFF,
    "line separator": 0x2028, "paragraph separator": 0x2029, "soft hyphen": 0x00AD,
    "no-break space": 0x00A0, "zero width joiner": 0x200D, "zero width space": 0x200B,
    "zero width non-joiner": 0x200C, "emoji variation selector": 0xFE0F, "text variation selector": 0xFE0E,
    "skin tone modifier": 0x1F3FD, "regional indicator": 0x1F1E8, "variation selector supplement": 0xE0100,
    "Thai": 0x0E2A, "Devanagari": 0x0928, "Hebrew": 0x05E9, "Arabic": 0x0645, "Chinese": 0x4F60,
    "Japanese hiragana": 0x3053, "Korean": 0xC548, "astral Han": 0x20BB7,
}
SOUP_HEADINGS = 16  # headings in markdown-feature-soup.md, counted by hand (setext 2, ATX 6, closed 1, rich 1, ### 6)


def decode_strict(t, name, data, codec):
    """Decode `data` with `codec`, recording a failure and returning None when it cannot."""
    try:
        return data.decode(codec)
    except UnicodeDecodeError as error:
        t.check(False, f"{name}: does not decode as {codec} ({error})")
        return None


def is_not_utf8(t, name, data):
    """Record a check that `data` is NOT valid UTF-8 (a legacy encoding must not pass as UTF-8)."""
    try:
        data.decode("utf-8")
        t.check(False, f"{name}: also valid UTF-8, so its encoding hides nothing")
    except UnicodeDecodeError:
        t.check(True, "")


def check_markdown(t, name, data, expected):
    """Markdown checks: valid UTF-8, the heading count, and the per-file hazards."""
    text = decode_strict(t, name, data, "utf-8")
    if text is None:
        return
    t.check(count_markdown_headings(text) == expected["headings"], f"{name}: heading count differs from the manifest")
    if name.endswith("markdown-feature-soup.md"):
        t.check(expected["headings"] == SOUP_HEADINGS, f"{name}: {expected['headings']} headings, expected {SOUP_HEADINGS}")
        for needle in ("[^1]:", "[docs]:", "~~~", "```", "> > >", "|:--", "<details>", "  \n"):
            t.check(needle in text, f"{name}: missing the feature {needle!r}")
    elif name.endswith("markdown-very-long.md"):
        t.check(len(re.findall(r"^## Section \d+:", text, re.M)) == 400, f"{name}: not 400 sections")
        t.check(text.count("| Measure |") == 20, f"{name}: not a table every 20 sections")
    elif name.endswith("unicode-heavy.md"):
        for label, code_point in REQUIRED_CODE_POINTS.items():
            t.check(chr(code_point) in text, f"{name}: missing {label} (U+{code_point:04X})")
        t.check(not any(0xD800 <= ord(c) <= 0xDFFF for c in text), f"{name}: holds a lone surrogate")
        labelled = [line for line in text.split("\n") if line and not line.startswith("#") and ": " in line]
        t.check(len(labelled) == expected["hazard_lines"],
                f"{name}: {len(labelled)} labelled lines, manifest says {expected['hazard_lines']}")


def check_text_variant(t, name, data, variant):
    """Check one encoded passage file: BOM, decoding, line endings, and legacy-encoding bytes."""
    t.check(data.startswith(variant.bom), f"{name}: wrong byte order mark")
    text = decode_strict(t, name, data, "utf-16" if variant.bom else variant.codec)  # Python reads the BOM itself
    if text is None:
        return
    t.check(re.split(r"\r\n|\r|\n", text) == variant.lines() + [""], f"{name}: decoded text is not the passage")
    t.check(not text.startswith("﻿"), f"{name}: the BOM leaked into the text")
    if variant.newline == "\r\n":
        t.check(text.count("\r\n") == text.count("\n") == text.count("\r"), f"{name}: line endings are not all CRLF")
    elif variant.newline == "\r":
        t.check("\n" not in text and "\r" in text, f"{name}: line endings are not bare CR")
    else:
        t.check("\r" not in text, f"{name}: a CR appears in an LF file")
    if variant.codec in ("latin-1", "cp1252"):
        is_not_utf8(t, name, data)
    if variant.codec == "cp1252":
        t.check(b"\x93" in data and b"\x80" in data, f"{name}: lacks the 0x80 to 0x9F bytes")


def check_text(t, name, data, expected):
    """Plain text checks: each encoding, BOM and line ending is what its name says."""
    base = name.split("/")[-1]
    if base in TEXT_VARIANTS:
        check_text_variant(t, name, data, TEXT_VARIANTS[base][0])
        return
    text = decode_strict(t, name, data, "utf-8")
    if text is None:
        return
    if base == "text-form-feeds.txt":
        t.check(text.count("\f") == 2 and len(text.split("\f")) == expected["pages"], f"{name}: wrong form feed count")
    elif base == "text-all-caps-headings.txt":
        lines = text.split("\n")
        # An all-caps line with a blank line (or the file edge) on both sides stands alone like a heading.
        alone = [line for i, line in enumerate(lines)
                 if line.isupper() and (i == 0 or not lines[i - 1]) and (i + 1 >= len(lines) or not lines[i + 1])]
        for heading in CAPS_HEADINGS:
            t.check(heading in alone, f"{name}: heading {heading!r} is not an all-caps line on its own")
        t.check(len(CAPS_HEADINGS) == expected["headings"], f"{name}: heading count differs from the manifest")
        for decoy in CAPS_DECOYS:
            t.check(any(decoy in line for line in lines), f"{name}: decoy {decoy!r} missing")
    elif base == "text-one-long-line.txt":
        t.check("\n" not in text and "\r" not in text, f"{name}: has a line ending")


class HeadingCounter(HTMLParser):
    """Counts h1 to h6 start tags and records the title, as a tolerant HTML reader would.

    Python's parser treats script and style content as raw text, so tags written
    inside them (a decoy) are not counted.
    """

    def __init__(self):
        super().__init__()
        self.headings, self.title, self.in_title = 0, "", False

    def handle_starttag(self, tag, attrs):
        if re.fullmatch(r"h[1-6]", tag):
            self.headings += 1
        self.in_title = tag == "title"

    def handle_endtag(self, tag):
        self.in_title = False

    def handle_data(self, data):
        if self.in_title:
            self.title += data


def check_html(t, name, data, expected):
    """HTML checks: bytes match the declared charset, the parse counts match, decoy text is present."""
    t.check(b'<meta charset="windows-1252">' in data, f"{name}: missing the charset declaration")
    is_not_utf8(t, name, data)
    text = decode_strict(t, name, data, "cp1252")
    if text is None:
        return
    parser = HeadingCounter()
    parser.feed(text)
    parser.close()
    t.check(parser.headings == expected["headings"], f"{name}: {parser.headings} headings parsed, manifest says {expected['headings']}")
    t.check(parser.title == expected["title"], f"{name}: title is {parser.title!r}")
    t.check("SCRIPT TEXT MUST NOT BE READ" in text and "STYLE TEXT MUST NOT BE READ" in text,
            f"{name}: the decoy script or style text is missing")
    t.check("“" in text and "€" in text, f"{name}: lacks the 0x80 to 0x9F characters")


# Which structural checker handles which file extension.
CHECKERS = {".epub": check_epub, ".docx": check_docx, ".md": check_markdown,
            ".txt": check_text, ".html": check_html}


def sha_map(folder):
    """Map every file name in `folder` to its SHA-256."""
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path(folder).iterdir())}


def check_run(t, label, folder, large):
    """Check one written corpus folder: manifest, sizes, and each file's structure."""
    folder = Path(folder)
    manifest = json.loads((folder / MANIFEST_NAME).read_text(encoding="utf-8"))
    listed = [f["name"] for f in manifest["files"]]
    on_disk = sorted(p.name for p in folder.iterdir() if p.name != MANIFEST_NAME)
    t.check(sorted(listed) == on_disk, f"{label}: manifest and folder disagree ({sorted(set(listed) ^ set(on_disk))})")
    t.check(listed == sorted(listed), f"{label}: manifest is not sorted by name")
    t.check(bool(manifest["skipped"]) and all(s["reason"] for s in manifest["skipped"]), f"{label}: skipped list missing reasons")
    total = 0
    for item in manifest["files"]:
        name = item["name"]
        data = (folder / name).read_bytes()
        total += len(data)
        t.check(len(data) == item["bytes"], f"{label}: {name} size differs from the manifest")
        t.check(hashlib.sha256(data).hexdigest() == item["sha256"], f"{label}: {name} hash differs from the manifest")
        t.check(bool(item["hazard"]), f"{label}: {name} has no hazard sentence")
        t.check(name == name.lower() and " " not in name, f"{label}: {name} is not a plain lower-case name")
        if name in LARGE_WINDOWS:
            low, high = LARGE_WINDOWS[name]
            t.check(low <= len(data) <= high, f"{label}: {name} is {len(data)} bytes, outside {low} to {high}")
        else:
            t.check(len(data) < MAX_FILE_BYTES, f"{label}: {name} is {len(data)} bytes, over the limit")
        suffix = Path(name).suffix
        checker = CHECKERS.get(suffix)
        t.check(checker is not None, f"{label}: no checker for {suffix} ({name})")
        if checker:
            checker(t, f"{label}/{name}", data, item["expected"])
    if not large:
        t.check(total < MAX_CORPUS_BYTES, f"{label}: corpus is {total} bytes, over the limit")


# Size windows (min, max) in bytes for the heavy files that only --large writes.
# The 40-chapter EPUB is small once zipped, so it keeps the normal per-file limit.
LARGE_WINDOWS = {
    "markdown-very-long.md": (5_000_000, 5_500_000),
    "text-one-long-line.txt": (3_000_000, 3_300_000),
}


def selftest():
    """Generate corpora into temp folders and check them; return the exit status."""
    t = Tester()
    with tempfile.TemporaryDirectory(prefix="make-corpus-selftest-") as scratch:
        scratch = Path(scratch)
        quiet = lambda line: None  # noqa: E731 - selftest output stays short
        runs = {"a": (DEFAULT_SEED, False), "b": (DEFAULT_SEED, False), "c": (DEFAULT_SEED + 1, False), "large": (DEFAULT_SEED, True)}
        for label, (seed, large) in runs.items():
            write_corpus(scratch / label, seed, large, say=quiet)
        for label, (_, large) in runs.items():
            check_run(t, label, scratch / label, large)

        # Determinism: the same seed gives identical bytes; another seed changes something.
        t.check(sha_map(scratch / "a") == sha_map(scratch / "b"), "two runs with one seed differ")
        t.check(sha_map(scratch / "a") != sha_map(scratch / "c"), "a different seed changed nothing")
        soup = "markdown-feature-soup.md"
        t.check(sha_map(scratch / "a")[soup] != sha_map(scratch / "c")[soup], "a different seed left the Markdown soup unchanged")

        # Folder safety: refuse foreign files, replace our own, drop stale large files.
        foreign = scratch / "foreign"
        foreign.mkdir()
        (foreign / "mine.txt").write_text("keep me")
        try:
            write_corpus(foreign, DEFAULT_SEED, False, say=quiet)
            t.check(False, "a folder with foreign files was not refused")
        except CorpusError:
            t.check((foreign / "mine.txt").exists(), "a refused folder lost a file")
        write_corpus(scratch / "large", DEFAULT_SEED, False, say=quiet)  # rewrite the large folder without --large
        t.check(sha_map(scratch / "large") == sha_map(scratch / "a"), "rewriting did not drop the large-only files")
        (scratch / "large" / "stray.txt").write_text("not ours")
        try:
            write_corpus(scratch / "large", DEFAULT_SEED, False, say=quiet)
            t.check(False, "a corpus folder with a stray file was not refused")
        except CorpusError:
            t.check(True, "")

    if t.failures:
        for line in t.failures:
            print(f"FAIL: {line}")
        print(f"selftest: {t.checks} checks, {len(t.failures)} failed")
        return 1
    print(f"selftest: {t.checks} checks, all passed")
    return 0


# --------------------------------------------------------------------------
# Command line
# --------------------------------------------------------------------------


def main(argv=None):
    """Parse the command line and run; return the process exit status."""
    parser = argparse.ArgumentParser(
        description="Write a folder of nasty-but-valid EPUB, DOCX, Markdown, text, HTML and PDF files "
                    "for testing TextMouth's importers.")
    parser.add_argument("--out", metavar="DIR", default=str(Path(tempfile.gettempdir()) / "textmouth-corpus"),
                        help="folder to write (default: a textmouth-corpus folder in the temp directory)")
    parser.add_argument("--seed", metavar="N", type=int, default=DEFAULT_SEED,
                        help=f"seed for generated filler text (default {DEFAULT_SEED}); one seed gives identical files")
    parser.add_argument("--large", action="store_true",
                        help="also write the heavy files (a 5 MB Markdown, a 3 MB one-line text, a 40-chapter EPUB)")
    parser.add_argument("--selftest", action="store_true", help="check the generator itself in a temp folder and exit")
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    try:
        write_corpus(args.out, args.seed, args.large)
    except CorpusError as error:
        print(f"make-corpus.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
