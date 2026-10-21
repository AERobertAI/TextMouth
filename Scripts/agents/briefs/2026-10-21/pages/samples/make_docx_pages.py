#!/usr/bin/env python3
"""Makes TestData/format-samples/docx/page-breaks.docx (PG07), the DOCX sample
that holds every kind of page start TextMouth reads.

Usage: python3 -I make_docx_pages.py OUTPUT.docx

The package is deterministic (fixed timestamps, fixed order), so running this
again writes the same bytes. It has the four parts a DOCX needs
([Content_Types].xml, _rels/.rels, word/document.xml, word/styles.xml) and the
document's relationships part that points at the styles.

The document, in order (PAGE is the page a break begins, LABEL its label):

  section 1 (decimal, from page 1)
    Title paragraph                                  page 1, label 1
    "runs on and" / w:br page / "continues here"     page 2, label 2 (mid-paragraph)
    paragraph in style ChapterStart (pageBreakBefore) page 3, label 3
    paragraph ending in a page w:br
    paragraph starting with w:lastRenderedPageBreak   page 4, label 4 (the two merge)
    paragraph that ends section 1 (holds its sectPr)
  section 2 (nextPage, lowerRoman, start 1)
    paragraph                                        page 5, label i
    paragraph with a page w:br in its middle         page 6, label ii (ends section 2)
  section 3 (the body's sectPr: nextPage, decimal, start 1)
    paragraph                                        page 7, label 1
    two-row table, w:lastRenderedPageBreak in row 2  page 8, label 2 (marker after the table)
    Heading1 paragraph with a page w:br in its middle page 9, label 3 (marker before the heading)
"""
import sys
import zipfile

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PAGE_BREAK = '<w:br w:type="page"/>'
RENDERED_BREAK = "<w:lastRenderedPageBreak/>"


def text(value):
    """A w:t element holding `value` (whitespace kept)."""
    return f'<w:t xml:space="preserve">{value}</w:t>'


def run(*children):
    """A run holding `children` (already-built elements)."""
    return "<w:r>" + "".join(children) + "</w:r>"


def paragraph(*runs, properties=""):
    """A paragraph whose w:pPr holds `properties` (omitted when empty)."""
    ppr = f"<w:pPr>{properties}</w:pPr>" if properties else ""
    return "<w:p>" + ppr + "".join(runs) + "</w:p>"


def plain(value, properties=""):
    """A paragraph of one run of `value`."""
    return paragraph(run(text(value)), properties=properties)


def style(style_id, name, based_on=None, properties="", default=False):
    """A paragraph style."""
    default_attribute = ' w:default="1"' if default else ""
    based = f'<w:basedOn w:val="{based_on}"/>' if based_on else ""
    ppr = f"<w:pPr>{properties}</w:pPr>" if properties else ""
    return (f'<w:style w:type="paragraph"{default_attribute} w:styleId="{style_id}">'
            f'<w:name w:val="{name}"/>{based}{ppr}</w:style>')


def section(type_value, number_type=""):
    """A w:sectPr whose break starts a page (or not) and numbers its pages."""
    return f'<w:sectPr><w:type w:val="{type_value}"/>{number_type}</w:sectPr>'


def table(*rows):
    """A table of rows of cells; each cell is the list of its paragraphs."""
    body = "".join(
        "<w:tr>" + "".join("<w:tc>" + "".join(cell) + "</w:tc>" for cell in row) + "</w:tr>"
        for row in rows)
    grid = "<w:tblGrid><w:gridCol w:w=\"4000\"/><w:gridCol w:w=\"4000\"/></w:tblGrid>"
    return "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/></w:tblPr>" + grid + body + "</w:tbl>"


def document():
    """The text part of the sample."""
    section_one = section("nextPage")
    section_two = section("nextPage", '<w:pgNumType w:fmt="lowerRoman" w:start="1"/>')
    section_three = section("nextPage", '<w:pgNumType w:start="1"/>')
    body = [
        # Page 1: the title.
        plain("Pages in a Word Document", '<w:pStyle w:val="Title"/>'),
        # Page 2 begins mid-paragraph, at a page w:br inside one run.
        paragraph(run(text("The first page runs on and"), PAGE_BREAK, text("continues here on the second page."))),
        # Page 3 begins at a paragraph whose style says pageBreakBefore.
        plain("The third page begins with a paragraph in a style that starts a page.",
              '<w:pStyle w:val="ChapterStart"/>'),
        # Page 4: an explicit break ends this paragraph, and Word's layout
        # note starts the next: one page, not two.
        paragraph(run(text("This paragraph ends with a hard page break.")), run(PAGE_BREAK)),
        paragraph(run(RENDERED_BREAK, text("The fourth page begins here, once, although two breaks mark it."))),
        # The last paragraph of section 1 holds the section's properties.
        plain("The first section ends on the fourth page.", section_one),
        # Section 2: pages i and ii. Its sectPr stands in its last paragraph.
        plain("The second section is numbered in lowercase Roman numerals, and this is page i."),
        paragraph(run(text("This page ends here and")), run(PAGE_BREAK, text("page ii begins in the middle of a paragraph.")),
                  properties=section_two),
        # Section 3: restarts at page 1; its sectPr is the body's last.
        plain("The third section restarts at page 1 in decimal numbers."),
        table(
            [[plain("Row one, cell A.")], [plain("Row one, cell B.")]],
            [[paragraph(run(RENDERED_BREAK, text("Row two, cell A.")))], [plain("Row two, cell B.")]],
        ),
        paragraph(run(text("A heading that")), run(PAGE_BREAK, text("crosses a page")), properties='<w:pStyle w:val="Heading1"/>'),
        section_three,
    ]
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            f'<w:document xmlns:w="{W}" xmlns:r="{R}"><w:body>' + "".join(body) + "</w:body></w:document>")


def styles():
    """The styles part: Normal, Title, Heading 1, and ChapterStart (Normal plus pageBreakBefore)."""
    definitions = [
        style("Normal", "Normal", default=True),
        style("Title", "Title", based_on="Normal"),
        style("Heading1", "heading 1", based_on="Normal", properties='<w:outlineLvl w:val="0"/>'),
        style("ChapterStart", "Chapter Start", based_on="Normal", properties="<w:pageBreakBefore/>"),
    ]
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            f'<w:styles xmlns:w="{W}">' + "".join(definitions) + "</w:styles>")


PARTS = [
    ("[Content_Types].xml",
     '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
     '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
     '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
     '<Default Extension="xml" ContentType="application/xml"/>'
     '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
     '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
     "</Types>"),
    ("_rels/.rels",
     '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
     '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
     f'<Relationship Id="rId1" Type="{R}/officeDocument" Target="word/document.xml"/>'
     "</Relationships>"),
    ("word/_rels/document.xml.rels",
     '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
     '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
     f'<Relationship Id="rId1" Type="{R}/styles" Target="styles.xml"/>'
     "</Relationships>"),
]


def main():
    """Write the package named by the one argument."""
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    parts = PARTS + [("word/document.xml", document()), ("word/styles.xml", styles())]
    with zipfile.ZipFile(sys.argv[1], "w") as archive:
        for name, content in parts:
            # A fixed timestamp and permissions keep the bytes the same on every run.
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 21, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, content.encode("utf-8"))


if __name__ == "__main__":
    main()
