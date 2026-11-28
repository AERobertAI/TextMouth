#!/usr/bin/env python3
"""Makes TestData/format-samples/mobi/ferry-notes-ncx.mobi, the MOBI 6 sample
whose contents (NCX index) has two levels (FMT42).

The book is written here, so it is CC0-1.0: a small EPUB with a two-level
table of contents and one picture with alt text, converted by calibre's
`ebook-convert` as an old-style MOBI (`--mobi-file-type old`, MOBI 6, no KF8
part, PalmDOC compression).

calibre writes a new identifier and date into every conversion, so the bytes
differ at each run; the sample in the repository is the one the tests were
written against, and its sha256 is in samples.tsv.

Usage: python3 -I Scripts/make-mobi-ncx-sample.py [output.mobi]
The default output is TestData/format-samples/mobi/ferry-notes-ncx.mobi.
"""
import os
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib

CALIBRE = "/Applications/calibre.app/Contents/MacOS/ebook-convert"
REPOSITORY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_OUTPUT = os.path.join(REPOSITORY, "TestData/format-samples/mobi/ferry-notes-ncx.mobi")

# The book: three chapters, the first with two sections. The tests look for
# these sentences, so change them only together with MOBIParserTests.
CHAPTERS = [
    ("ch1.xhtml", "The Morning Crossing", [
        ("<p>The first ferry leaves the Tallow Quay at seven and reaches the island "
         "before the bakers have finished their loaves.</p>"),
        ("tickets", "Buying a Ticket",
         "<p>Tickets are sold from a hatch beside the net shed. The hatch opens when "
         "the kettle behind it boils.</p>"),
        ("timetable", "Reading the Timetable",
         "<p>The timetable is chalked on a slate, and the slate is wiped by the tide "
         "on any day the quay floods.</p>"),
    ]),
    ("ch2.xhtml", "The Evening Crossing", [
        ("<p>The last ferry returns at nine. Its lamp is lit by whoever arrives at "
         "the quay first, and it is never lit twice by the same person.</p>"),
    ]),
    ("ch3.xhtml", "Lost Property", [
        ("<p>Umbrellas are kept for a month, gloves for a week, and keys for as long "
         "as it takes someone to ask.</p>"
         "<p><img src=\"map.png\" alt=\"A chalk map of the pier\"/></p>"),
    ]),
]


def tiny_png():
    """A 1 by 1 grey PNG, made by hand so no image library is needed."""
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0)
    pixels = zlib.compress(b"\x00\x80")
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")


def chapter_xhtml(title, parts):
    """One chapter's XHTML: an h1, its opening paragraphs, and each section under an h2."""
    body = ["<h1>%s</h1>" % title]
    for part in parts:
        if isinstance(part, str):
            body.append(part)
        else:
            anchor, heading, paragraph = part
            body.append('<h2 id="%s">%s</h2>' % (anchor, heading))
            body.append(paragraph)
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>%s</title></head>\n'
            "<body>\n%s\n</body></html>\n" % (title, "\n".join(body)))


def nav_point(order, label, source, inner=""):
    """One NCX navPoint, numbered `order` in reading order, holding `inner`."""
    return ('<navPoint id="n%d" playOrder="%d"><navLabel><text>%s</text></navLabel>'
            '<content src="%s"/>%s</navPoint>' % (order, order, label, source, inner))


def navigation():
    """The EPUB 2 NCX: each chapter a navPoint, each section a navPoint inside it."""
    order = 0
    points = []
    for name, title, parts in CHAPTERS:
        order += 1
        chapter_order = order
        sections = []
        for part in parts:
            if not isinstance(part, str):
                order += 1
                sections.append(nav_point(order, part[1], "%s#%s" % (name, part[0])))
        points.append(nav_point(chapter_order, title, name, "".join(sections)))
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
            '<head><meta name="dtb:uid" content="textmouth-ferry-notes"/></head>'
            "<docTitle><text>Ferry Notes</text></docTitle><navMap>%s</navMap></ncx>" % "".join(points))


def build_epub(path):
    """Writes the source EPUB to `path`."""
    manifest = "".join(
        '<item id="c%d" href="%s" media-type="application/xhtml+xml"/>' % (i, name)
        for i, (name, _, _) in enumerate(CHAPTERS, 1))
    spine = "".join('<itemref idref="c%d"/>' % i for i in range(1, len(CHAPTERS) + 1))
    package = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>Ferry Notes</dc:title><dc:creator>Ottoline Brannock</dc:creator>'
        '<dc:language>en</dc:language><dc:identifier id="id">textmouth-ferry-notes</dc:identifier>'
        "</metadata><manifest>%s"
        '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
        '<item id="map" href="map.png" media-type="image/png"/></manifest>'
        '<spine toc="ncx">%s</spine></package>' % (manifest, spine))
    container = (
        '<?xml version="1.0"?>\n'
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
        "</rootfiles></container>")
    with zipfile.ZipFile(path, "w") as archive:
        # The mimetype entry comes first and is stored, as an EPUB requires.
        archive.writestr("mimetype", "application/epub+zip", zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", container, zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/content.opf", package, zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/toc.ncx", navigation(), zipfile.ZIP_DEFLATED)
        archive.writestr("OEBPS/map.png", tiny_png(), zipfile.ZIP_STORED)
        for name, title, parts in CHAPTERS:
            archive.writestr("OEBPS/" + name, chapter_xhtml(title, parts), zipfile.ZIP_DEFLATED)


def main():
    output = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUTPUT
    with tempfile.TemporaryDirectory() as folder:
        source = os.path.join(folder, "ferry-notes.epub")
        build_epub(source)
        subprocess.run(
            [CALIBRE, source, output, "--mobi-file-type", "old", "--no-inline-toc"],
            check=True)
    print("wrote", output, os.path.getsize(output), "bytes")


if __name__ == "__main__":
    main()
