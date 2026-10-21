#!/usr/bin/env python3
"""Write TestData/format-samples/pdf/labelled-pages.pdf (PG06).

A five-page PDF with one line of text per page ("This is page one." ...
"This is page five.") and a /PageLabels tree that labels the pages
i, ii, 1, 2, A-1. It is written by hand (objects, one Helvetica font, one
content stream per page, a cross-reference table with exact byte offsets),
with no third-party module, so the file can be made again anywhere.

Usage: python3 -I make_labelled_pdf.py OUTPUT.pdf
"""
import sys

# The words on each page, in page order.
WORDS = ["one", "two", "three", "four", "five"]

# The page-label tree: pages 0-1 lowercase roman (i, ii), pages 2-3 decimal
# from 1 (1, 2), page 4 decimal from 1 with the prefix "A-" (A-1).
PAGE_LABELS = "<< /Nums [0 << /S /r >> 2 << /S /D >> 4 << /S /D /P (A-) >>] >>"


def build() -> bytes:
    """Return the whole PDF file as bytes."""
    page_count = len(WORDS)
    # Object numbers: 1 catalog, 2 page tree, 3 font, then a page and its
    # content stream for each page (4+2k and 5+2k).
    page_ids = [4 + 2 * k for k in range(page_count)]
    objects = {
        1: f"<< /Type /Catalog /Pages 2 0 R /PageLabels {PAGE_LABELS} >>",
        2: "<< /Type /Pages /Kids [" + " ".join(f"{p} 0 R" for p in page_ids)
           + f"] /Count {page_count} >>",
        3: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    }
    for k, word in enumerate(WORDS):
        page_id = page_ids[k]
        # The page's one line of text, 18 point, an inch in from the corner.
        stream = f"BT /F1 18 Tf 72 700 Td (This is page {word}.) Tj ET"
        objects[page_id] = (
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            f"/Resources << /Font << /F1 3 0 R >> >> /Contents {page_id + 1} 0 R >>"
        )
        objects[page_id + 1] = f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream"

    # Write the objects in order, noting each one's byte offset.
    out = bytearray(b"%PDF-1.4\n")
    offsets = {}
    for number in sorted(objects):
        offsets[number] = len(out)
        out += f"{number} 0 obj\n{objects[number]}\nendobj\n".encode("ascii")

    # The cross-reference table: every entry is exactly 20 bytes.
    xref_start = len(out)
    size = max(objects) + 1
    out += f"xref\n0 {size}\n".encode("ascii")
    out += b"0000000000 65535 f \n"
    for number in range(1, size):
        out += f"{offsets[number]:010d} 00000 n \n".encode("ascii")
    out += f"trailer\n<< /Size {size} /Root 1 0 R >>\nstartxref\n{xref_start}\n%%EOF\n".encode("ascii")
    return bytes(out)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: make_labelled_pdf.py OUTPUT.pdf")
    with open(sys.argv[1], "wb") as handle:
        handle.write(build())
