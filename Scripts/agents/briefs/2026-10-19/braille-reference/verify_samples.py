"""Independent checks of the braille samples.  Prints PASS/FAIL lines; exit 1 on any FAIL.

Usage: python3 -I verify_samples.py <samples dir> <system liblouis tables dir> <pg1342.txt>

The checks do not trust make_samples.py's output: they re-derive facts from outside sources
(liblouis tables as shipped in macOS, the PEF RELAX NG rules read from the spec's schema,
the Gutenberg text) and re-parse the written files.
"""
import sys
sys.dont_write_bytecode = True
import os
import re
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ueb  # noqa: E402

FAILS = []


def check(name, ok, detail=""):
    """Record and print one check."""
    print(("PASS " if ok else "FAIL ") + name + ((" :: " + detail) if detail and not ok else ""))
    if not ok:
        FAILS.append(name)


def liblouis_defs(tables_dir):
    """Parse forward character definitions from the UEB table files into {char: dots-string}."""
    defs = {}
    for fname in ("en-ueb-chardefs.uti", "latinLetterDef6Dots.uti"):
        with open(os.path.join(tables_dir, fname), encoding="utf-8") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 3 or parts[0] not in ("punctuation", "lowercase", "litdigit", "sign"):
                    continue
                ch = parts[1]
                if ch.startswith("\\x"):
                    ch = chr(int(ch[2:], 16))
                elif ch == "\\\\":
                    ch = "\\"
                defs.setdefault((parts[0], ch), parts[2].replace("-", ","))
    return defs


def dots_of(cell_list):
    """Cells to the 'a,b' liblouis dot notation (cells joined by commas)."""
    return ",".join("".join(str(i + 1) for i in range(6) if c >> i & 1) for c in cell_list)


def main(root, tables, gutenberg):
    # 1. The 64-character ASCII table against liblouis's own display table.
    dis = {}
    with open(os.path.join(tables, "en-us-brf.dis"), encoding="utf-8") as f:
        for line in f:
            p = line.split()
            if len(p) == 3 and p[0] == "display":
                ch = "\\" if p[1] == "\\\\" else (" " if p[1] == "\\s" else p[1])
                dis[ch] = 0 if p[2] == "0" else ueb.cell(p[2])
    ok = len(dis) == 64 and all(ueb.CELL_BY_ASCII[ch] == v for ch, v in dis.items())
    check("ASCII table matches liblouis en-us-brf.dis (64 of 64)", ok, "%d entries" % len(dis))

    # 2. Every print character used in the sample, against liblouis's UEB definitions.
    text_path = os.path.join(root, "brf", "pride-and-prejudice-ch1.txt")
    with open(text_path, encoding="utf-8") as f:
        sample_text = f.read()
    defs = liblouis_defs(tables)
    used = sorted(set(sample_text) - set(" \n_"))
    bad = []
    for ch in used:
        if ch.isalpha():
            want = defs.get(("lowercase", ch.lower()))
            mine = dots_of([ueb.LETTER[ch.lower()]])
        elif ch.isdigit():
            want = defs.get(("litdigit", ch))
            mine = dots_of([ueb.DIGIT[ch]])
        else:
            want = defs.get(("punctuation", ch)) or defs.get(("sign", ch))
            mine = dots_of(ueb.PUNCT[ch])
        if want != mine:
            bad.append((ch, want, mine))
    check("every printed character's cells match liblouis en-ueb-chardefs (%d characters)" % len(used),
          not bad, str(bad))
    g1 = open(os.path.join(tables, "en-ueb-g1.ctb"), encoding="utf-8").read()
    for rule, mine in (("capsletter", [ueb.CAPITAL_SIGN]), ("begcapsword", ueb.CAPITALS_WORD),
                       ("begcapsphrase", ueb.CAPITALS_PASSAGE), ("endcapsphrase after", ueb.CAPITALS_TERMINATOR),
                       ("numsign", [ueb.NUMERIC_INDICATOR]), ("nocontractsign", [ueb.GRADE1_SYMBOL]),
                       ("begemphword italic", ueb.ITALIC_WORD)):
        m = re.search(r"^%s +([0-9-]+)" % re.escape(rule), g1, re.M)
        check("indicator %s = %s" % (rule, m and m.group(1)),
              bool(m) and m.group(1).replace("-", ",") == dots_of(mine))

    # 3. BRF structure, read back from the file's bytes.
    brf_path = os.path.join(root, "brf", "pride-and-prejudice-ch1-grade1.brf")
    data = open(brf_path, "rb").read()
    check("BRF: only 0x20-0x5F, CR, LF, FF", all(b in (13, 10, 12) or 0x20 <= b <= 0x5F for b in data))
    check("BRF: every line ends CR LF (no bare CR or LF)",
          data.replace(b"\r\n", b"").count(b"\n") == 0 and data.replace(b"\r\n", b"").count(b"\r") == 0)
    check("BRF: exactly one form feed, between the two pages", data.count(b"\f") == 1)
    pages = ueb.read_brf(data)
    check("BRF: 2 pages of 25 lines", [len(p) for p in pages] == [25, 25], str([len(p) for p in pages]))
    check("BRF: no line over 40 cells", all(len(l) <= 40 for p in pages for l in p))
    for n, pg in enumerate(pages, 1):
        footer = pg[-1]
        want = ueb.number_cells(n)
        check("BRF page %d: braille page number %s at the right margin of line 25, 3+ blanks before"
              % (n, ueb.to_ascii(want)),
              len(footer) == 40 and footer[-len(want):] == want and not any(footer[:-len(want)])
              and len(footer) - len(want) >= 3)
    check("BRF page 1: title on line 1, blank line 2, heading on line 3, blank line 4",
          pages[0][0] and pages[0][1] == [] and pages[0][2] and pages[0][3] == [])
    for i in (0, 2):
        line = pages[0][i]
        lead = next(k for k, c in enumerate(line) if c)          # blank cells before the text
        width = len(line) - lead                                   # cells of text
        check("BRF page 1 line %d: centered (left blanks %d, right blanks %d, 3+ each side)"
              % (i + 1, lead, 40 - lead - width),
              lead == (40 - width) // 2 and lead >= 3 and 40 - lead - width >= 3)
    # Paragraph first lines have two leading blanks (3-1 margins), runovers none.
    text_lines = [l for p in pages for l in p[:-1] if l]
    heads = text_lines[:2]
    body_lines = text_lines[2:]
    starts = [l for l in body_lines if l[:2] == [0, 0] and l[2] != 0]
    check("BRF: runover lines start in cell 1, paragraph lines in cell 3",
          all((l[:2] == [0, 0] and l[2] != 0) or l[0] != 0 for l in body_lines))

    # 4. Decode the BRF and compare with the print text (paragraph = indented line + runovers).
    decoded, cur = [], None
    for l in heads:
        decoded.append(ueb.decode_grade1(ueb.__dict__["trim"](l)).strip())
    for l in body_lines:
        s = ueb.decode_grade1(l)
        if l[:2] == [0, 0]:
            if cur is not None:
                decoded.append(cur)
            cur = s.strip()
        else:
            cur += " " + s.strip()
    decoded.append(cur)
    want_blocks = [b for b in sample_text.split("\n\n")]
    want_blocks[-1] = want_blocks[-1].rstrip("\n")
    check("BRF decodes back to the print text (title, heading, %d paragraphs)" % (len(want_blocks) - 2),
          decoded == want_blocks,
          "\n".join("%r != %r" % (a, b) for a, b in zip(decoded, want_blocks) if a != b)[:600])

    # 4b. The print text against the downloaded Gutenberg text.
    g = open(gutenberg, encoding="utf-8-sig").read().replace("\r\n", "\n")
    g = g[g.index("It is a truth universally"):]
    gparas = [re.sub(r"\s*\n\s*", " ", p.strip()) for p in re.split(r"\n\s*\n", g)]
    gparas = [p for p in gparas[:16] if not p.startswith(("[Illustration", "“He came down", "[_Copyright"))]
    check("print text equals Project Gutenberg #1342 paragraphs 1-12 (illustration caption skipped)",
          want_blocks[2:] == gparas[:len(want_blocks) - 2])

    # 5. PEF: the rules of pef-2008-1.rng, then equality with the BRF page rows.
    pef_path = os.path.join(root, "pef", "pride-and-prejudice-ch1-grade1.pef")
    ns = {"p": "http://www.daisy.org/ns/2008/pef", "dc": "http://purl.org/dc/elements/1.1/"}
    pef = ET.parse(pef_path).getroot()
    check("PEF: root is {pef-ns}pef, version 2008-1",
          pef.tag == "{%s}pef" % ns["p"] and pef.get("version") == "2008-1")
    meta = pef.find("p:head/p:meta", ns)
    check("PEF: dc:format = application/x-pef+xml and dc:identifier present",
          meta is not None and meta.findtext("dc:format", namespaces=ns) == "application/x-pef+xml"
          and bool(meta.findtext("dc:identifier", namespaces=ns)))
    check("PEF: dc:date matches yyyy-mm-dd", re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", meta.findtext("dc:date", namespaces=ns)) is not None)
    vol = pef.find("p:body/p:volume", ns)
    check("PEF: volume has cols, rows, rowgap, duplex", all(vol.get(a) is not None for a in ("cols", "rows", "rowgap", "duplex"))
          and vol.get("duplex") in ("true", "false") and int(vol.get("cols")) > 0 and int(vol.get("rows")) > 0
          and int(vol.get("rowgap")) >= 0)
    pef_pages = vol.findall("p:section/p:page", ns)
    check("PEF: at least one section with pages", len(pef_pages) == 2)
    rows_ok = all(re.fullmatch("[⠀-⣿]*", (r.text or "")) for pg in pef_pages for r in pg.findall("p:row", ns))
    check("PEF: every row is only U+2800-U+28FF", rows_ok)
    same = True
    for pg_el, pg in zip(pef_pages, pages):
        rows = pg_el.findall("p:row", ns)
        same &= len(rows) == len(pg) == int(vol.get("rows"))
        for r, l in zip(rows, pg):
            same &= (r.text or "") == ueb.to_unicode(ueb.trim(l)) and len(r.text or "") <= int(vol.get("cols"))
    check("PEF rows equal the BRF lines cell for cell (25 rows x 2 pages, none over 40 cells)", same)

    # 6. BRL.
    brl = open(os.path.join(root, "brl", "pride-and-prejudice-ch1-grade1.brl"), "rb").read()
    brl_lines = brl.decode("ascii").split("\r\n")[:-1]
    check("BRL: unformatted lines (one per paragraph), no form feeds, CR LF",
          b"\f" not in brl and len(brl_lines) == len(want_blocks) and brl.endswith(b"\r\n"))
    check("BRL decodes back to the print text",
          [ueb.decode_grade1(ueb.from_ascii(l)) for l in brl_lines] == want_blocks)

    # 6b. Encoder and decoder against hand-worked UEB Grade 1 examples (ICEB Rules 2013).
    for printed, braille in (("NASA", "⠠⠠⠝⠁⠎⠁"),
                             ("2024", "⠼⠃⠚⠃⠙"),
                             ("5a", "⠼⠑⠰⠁"),
                             ("3.14", "⠼⠉⠲⠁⠙"),
                             ("ONE TWO THREE", "⠠⠠⠠⠕⠝⠑ ⠞⠺⠕ ⠞⠓⠗⠑⠑⠠⠄"),
                             ("don't", "⠙⠕⠝⠄⠞"),
                             ("(a)", "⠐⠣⠁⠐⠜")):
        words = ueb.translate_paragraph(printed)
        cells_out = []
        for k, w in enumerate(words):
            cells_out += ([0] if k else []) + w
        got = ueb.to_unicode(cells_out).replace("⠀", " ")
        check("encode %r -> %s" % (printed, braille), got == braille, got)
        back = ueb.decode_grade1(cells_out)
        check("decode back to %r" % printed, back == printed.replace("'", "’"), back)

    # 7. Grade 2 file against hand-typed Unicode braille.
    g2 = ueb.read_brf(open(os.path.join(root, "brf", "grade2-short.brf"), "rb").read())[0]
    expect = ["⠠⠮ ⠃⠕⠽ ⠯ ⠛⠊⠗⠇ ⠉ ⠛ ⠾ ⠽⠲",
              "⠠⠮ ⠡⠥⠗⠡ ⠩⠕⠏ ⠊⠎ ⠕⠏⠢⠲",
              "⠠⠺⠑ ⠇ ⠎⠬⠬⠲"]
    got = [ueb.to_unicode(l).replace("⠀", " ") for l in g2[:3]]
    check("Grade 2 sample equals the hand-typed Unicode braille of the three sentences", got == expect, str(got))
    g2src = open(os.path.join(tables, "en-ueb-g2.ctb"), encoding="utf-8").read().splitlines()
    wanted = {"the": "2346", "and": "12346", "with": "23456", "ch": "16", "sh": "146", "en": "26",
              "ing": "346", "can": "14", "go": "1245", "like": "123", "you": "13456"}
    for w, d in wanted.items():
        hit = [l for l in g2src if not l.startswith("#") and re.search(r"(^| )%s( .*)? %s\b" % (w, d), l)]
        check("liblouis en-ueb-g2.ctb states %s = %s" % (w, d), bool(hit))
    print("\n%d failures" % len(FAILS))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:4]))
