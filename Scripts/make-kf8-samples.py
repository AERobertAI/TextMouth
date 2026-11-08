#!/usr/bin/env python3
"""Makes the KF8 samples of FMT48 in TestData/format-samples:

    azw3/quay-almanac.epub          the source EPUB, which is the yardstick the KF8 reading is compared with;
    azw3/quay-almanac.azw3          the book as an AZW3 (KF8 only);
    mobi/quay-almanac-hybrid.mobi   the book as a hybrid file (a MOBI 6 part, then a KF8 part).

The book is written here, so it is CC0-1.0: three XHTML documents with a
three-level table of contents (an EPUB 2 NCX), headings to level 3, emphasis,
a bulleted and a numbered list, a table, print page breaks (both an
`epub:type` one and a `role` one), a link between documents, a picture with
a description, and a chapter long enough that KF8 cuts its document into
several fragments. calibre's `ebook-convert` makes the two Kindle files.

calibre writes a new identifier and date into every conversion, so the bytes
differ at each run; the samples in the repository are the ones the tests were
written against, and their sha256 is in samples.tsv.

Usage:
    python3 -I Scripts/make-kf8-samples.py --epub-only OUTPUT.epub
        writes only the EPUB.
    python3 -I Scripts/make-kf8-samples.py
        writes the EPUB and both Kindle files into TestData/format-samples,
        running calibre's ebook-convert (EBOOK_CONVERT in the environment names it;
        the default is /Applications/calibre.app/Contents/MacOS/ebook-convert).
"""
import os
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib

CONVERTER = os.environ.get("EBOOK_CONVERT", "/Applications/calibre.app/Contents/MacOS/ebook-convert")
REPOSITORY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SAMPLES = os.path.join(REPOSITORY, "TestData/format-samples")


def tiny_png():
    """A 1 by 1 grey PNG, made by hand so no image library is needed."""
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"\x00\x80")) + chunk(b"IEND", b"")


def tide_lines():
    """About a hundred distinct sentences, so the first chapter is long enough to be cut into fragments."""
    places = ["the Tallow Quay", "the net shed", "the lamp steps", "the salt jetty", "the ropewalk", "the ferry hatch"]
    marks = ["rises to the second ring", "stands a hand below the weed line", "covers the lowest step",
             "leaves the slipway dry", "reaches the painted gauge", "holds still for a quarter of an hour"]
    for number in range(1, 101):
        yield "On day %d the water at %s %s, and the keeper writes it in the ledger." % (
            number, places[number % len(places)], marks[(number * 5) % len(marks)])


def documents():
    """The three documents of the book, as (file name, XHTML body)."""
    long_section = "".join("<p>%s</p>\n" % line for line in tide_lines())
    first = (
        '<h1 id="tides">Tides</h1>\n'
        "<p>The keeper of the quay records the water twice a day. Her notes are <em>short</em>, "
        "<strong>exact</strong>, and never rounded.</p>\n"
        '<span epub:type="pagebreak" role="doc-pagebreak" title="2" id="p2"></span>\n'
        "<p>Three things are always written down:</p>\n"
        "<ul><li>the hour</li><li>the height on the gauge</li><li>the direction of the wind</li></ul>\n"
        '<h2 id="spring">Spring tides</h2>\n'
        "<p>Spring tides come after the new moon and the full moon, and they are the ones that flood the lower road. "
        'See <a href="ch2.xhtml#timetable">the timetable</a> for the days the ferry does not run.</p>\n'
        '<h3 id="floods">Floods</h3>\n'
        "<p>A flood is a tide that reaches the third ring. The keeper rings the bell once for each ring reached.</p>\n"
        '<span epub:type="pagebreak" role="doc-pagebreak" title="3" id="p3"></span>\n'
        '<h2 id="neap">Neap tides</h2>\n'
        "<p>Neap tides are small and slow, and the keeper takes a day of rest on each.</p>\n"
        '<h2 id="ledger">From the ledger</h2>\n' + long_section)
    second = (
        '<h1 id="ferries">Ferries</h1>\n'
        '<p><img src="map.png" alt="A chalk map of the pier"/></p>\n'
        "<p>Two ferries serve the island, the morning boat and the evening boat.</p>\n"
        '<h2 id="timetable">Timetable</h2>\n'
        "<table><tr><th>Boat</th><th>Leaves</th></tr>"
        "<tr><td>Morning</td><td>seven o'clock</td></tr>"
        "<tr><td>Evening</td><td>nine o'clock</td></tr></table>\n"
        "<ol><li>Tickets are sold at the hatch.</li><li>The hatch opens when the kettle boils.</li></ol>\n")
    third = (
        '<h1 id="lost">Lost property</h1>\n'
        "<p>Umbrellas are kept for a month, gloves for a week, and keys for as long as it takes someone to ask.</p>\n"
        '<span epub:type="pagebreak" role="doc-pagebreak" title="9" id="p9"></span>\n'
        "<p>Nothing is ever thrown away on a Sunday.</p>\n")
    return [("ch1.xhtml", "Tides", first), ("ch2.xhtml", "Ferries", second), ("ch3.xhtml", "Lost property", third)]


def xhtml(title, body):
    """One document, with the EPUB 3 namespace bound so `epub:type` is a legal attribute."""
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
            "<head><title>%s</title></head>\n<body>\n%s</body></html>\n" % (title, body))


def nav_point(order, label, source, inner=""):
    """One NCX navPoint, numbered `order` in reading order, holding `inner`."""
    return ('<navPoint id="n%d" playOrder="%d"><navLabel><text>%s</text></navLabel>'
            '<content src="%s"/>%s</navPoint>' % (order, order, label, source, inner))


def navigation():
    """The EPUB 2 NCX: three chapters, the first with two sections, the first of those with a subsection."""
    floods = nav_point(3, "Floods", "ch1.xhtml#floods")
    spring = nav_point(2, "Spring tides", "ch1.xhtml#spring", floods)
    neap = nav_point(4, "Neap tides", "ch1.xhtml#neap")
    ledger = nav_point(5, "From the ledger", "ch1.xhtml#ledger")
    tides = nav_point(1, "Tides", "ch1.xhtml", spring + neap + ledger)
    ferries = nav_point(6, "Ferries", "ch2.xhtml", nav_point(7, "Timetable", "ch2.xhtml#timetable"))
    lost = nav_point(8, "Lost property", "ch3.xhtml")
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
            '<head><meta name="dtb:uid" content="textmouth-quay-almanac"/></head>'
            "<docTitle><text>Quay Almanac</text></docTitle><navMap>%s</navMap></ncx>" % (tides + ferries + lost))


def build_epub(path):
    """Writes the source EPUB to `path`."""
    parts = documents()
    manifest = "".join('<item id="c%d" href="%s" media-type="application/xhtml+xml"/>' % (i, name)
                       for i, (name, _, _) in enumerate(parts, 1))
    spine = "".join('<itemref idref="c%d"/>' % i for i in range(1, len(parts) + 1))
    package = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        "<dc:title>Quay Almanac</dc:title><dc:creator>Casimir Oyelaran</dc:creator>"
        '<dc:language>en</dc:language><dc:identifier id="id">textmouth-quay-almanac</dc:identifier>'
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
        for name, title, body in parts:
            archive.writestr("OEBPS/" + name, xhtml(title, body), zipfile.ZIP_DEFLATED)


def main():
    if "--epub-only" in sys.argv:
        output = os.path.abspath(sys.argv[-1])
        build_epub(output)
        print("wrote", output, os.path.getsize(output), "bytes")
        return
    epub = os.path.join(SAMPLES, "azw3/quay-almanac.epub")
    build_epub(epub)
    azw3 = os.path.join(SAMPLES, "azw3/quay-almanac.azw3")
    hybrid = os.path.join(SAMPLES, "mobi/quay-almanac-hybrid.mobi")
    subprocess.run([CONVERTER, epub, azw3, "--no-inline-toc"], check=True)
    subprocess.run([CONVERTER, epub, hybrid, "--mobi-file-type", "both", "--no-inline-toc"], check=True)
    for path in (epub, azw3, hybrid):
        print("wrote", path, os.path.getsize(path), "bytes")


if __name__ == "__main__":
    main()
