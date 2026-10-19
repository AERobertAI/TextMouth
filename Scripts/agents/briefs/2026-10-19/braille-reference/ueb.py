"""A small Grade 1 UEB encoder/decoder and BRF/PEF layout engine (research prototype).

Everything here is the lead's evidence for "how big is writing our own": the tables, the
translator, the page layout, the BRF/PEF writers, and the BRF reader/decoder.

Sources for the rules used (all read on 2026-10-17):
  * ICEB, The Rules of Unified English Braille (2013): letters, capitals (sec. 8), numeric
    indicator (sec. 6), grade 1 indicator (sec. 5), punctuation (sec. 7), typeforms (sec. 9).
  * BANA, Braille Formats: Principles of Print-to-Braille Transcription (2016): 40 cells,
    25 lines (1.7), 3-1 paragraph margins (1.9.2), no word division (1.10.1), braille page
    number on the last line at the right margin with 3+ blank cells before it (1.15.1),
    centered headings with a blank line before and after and 3+ blank cells at each side
    (4.4.1, 4.4.2), a title centered on line 1 of the first page of text (1.8.1a).
  * North American Braille ASCII (NABCC): the 64-character table below, cross-checked
    against liblouis's own en-us-brf.dis by verify_samples.py.
"""
import sys
sys.dont_write_bytecode = True

# --------------------------------------------------------------------------------------
# Cells.  A cell is an int 0..63: bit 0 = dot 1 ... bit 5 = dot 6 (Unicode U+2800 + value).
# --------------------------------------------------------------------------------------

def cell(dots: str) -> int:
    """Return the cell value for a string of dot digits such as '1245' ('' = blank)."""
    return sum(1 << (int(d) - 1) for d in dots)


def cells(*dot_strings: str) -> list:
    """Several dot strings to a list of cells: cells('6', '236') -> [32, 46]."""
    return [cell(d) for d in dot_strings]


# NABCC: the 64 ASCII characters 0x20..0x5F listed in order of their Unicode braille cell
# (U+2800 first).  Index = cell value.  Lowercase letters are read as their capitals.
ASCII_BY_CELL = " A1B'K2L@CIF/MSP\"E3H9O6R^DJG>NTQ,*5<-U8V.%[$+X!&;:4\\0Z7(_?W]#Y)="
assert len(ASCII_BY_CELL) == 64 and len(set(ASCII_BY_CELL)) == 64
CELL_BY_ASCII = {ch: i for i, ch in enumerate(ASCII_BY_CELL)}


def to_unicode(cell_list) -> str:
    """Cells to Unicode braille characters (U+2800 block)."""
    return "".join(chr(0x2800 + c) for c in cell_list)


def to_ascii(cell_list) -> str:
    """Cells to North American Braille ASCII."""
    return "".join(ASCII_BY_CELL[c] for c in cell_list)


def from_ascii(text: str) -> list:
    """Braille ASCII to cells; lowercase letters are read as capitals (the table's rule)."""
    return [CELL_BY_ASCII[ch.upper()] for ch in text]


# --------------------------------------------------------------------------------------
# UEB tables (Grade 1: no contractions).
# --------------------------------------------------------------------------------------

LETTER_DOTS = dict(zip("abcdefghijklmnopqrstuvwxyz", [
    "1", "12", "14", "145", "15", "124", "1245", "125", "24", "245",
    "13", "123", "134", "1345", "135", "1234", "12345", "1235", "234", "2345",
    "136", "1236", "2456", "1346", "13456", "1356"]))
LETTER = {ch: cell(d) for ch, d in LETTER_DOTS.items()}
# Digits are the letters a-j after the numeric indicator (ICEB 6.1): 1..9 = a..i, 0 = j.
DIGIT = {d: LETTER[l] for d, l in zip("1234567890", "abcdefghij")}
NUMERIC_INDICATOR = cell("3456")
CAPITAL_SIGN = cell("6")                      # one capital letter (ICEB 8.2)
CAPITALS_WORD = cells("6", "6")               # capitals word indicator (8.3)
CAPITALS_PASSAGE = cells("6", "6", "6")       # three or more words (8.4)
CAPITALS_TERMINATOR = cells("6", "3")         # terminates a passage (8.4)
GRADE1_SYMBOL = cell("56")                    # grade 1 symbol indicator (5.1)
ITALIC_WORD = cells("46", "2")                # italic word indicator (9.2)

# Punctuation: print mark -> cells (ICEB 7; each checked against liblouis en-ueb-chardefs.uti).
PUNCT = {
    ",": cells("2"), ".": cells("256"), ";": cells("23"), ":": cells("25"),
    "!": cells("235"), "?": cells("56", "236"),
    "“": cells("236"), "”": cells("356"),            # curly double quotes
    "‘": cells("6", "236"), "’": cells("6", "356"),   # curly single quotes
    "-": cells("36"), "—": cells("6", "36"), "–": cells("6", "36"),
    "(": cells("5", "126"), ")": cells("5", "345"),
    "…": cells("256", "256", "256"),
}
APOSTROPHE = cells("3")                                          # ICEB 7.1
STRAIGHT_QUOTE_OPEN, STRAIGHT_QUOTE_CLOSE = PUNCT["“"], PUNCT["”"]
SINGLE_OPEN, SINGLE_CLOSE = PUNCT["‘"], PUNCT["’"]


def _is_all_caps_word(word: str) -> bool:
    """True for a word with two or more letters, all of them capitals (e.g. 'NASA')."""
    letters = [c for c in word if c.isalpha()]
    return len(letters) >= 2 and all(c.isupper() for c in letters)


def translate_word(word: str, caps_word_started: bool = False) -> list:
    """Translate one space-free print word (with attached punctuation) to Grade 1 UEB cells.

    `caps_word_started` is True when a capitals-passage indicator already covers this word,
    so no per-word indicator is emitted.  Italic markup `_word_` (Gutenberg style) becomes
    an italic word indicator.
    """
    out = []
    # Typeform: an underscore pair around a whole word (after any opening punctuation) means
    # italic.  The word indicator goes just before the italic word, after an opening quote
    # and before any capitals indicator; a word indicator needs no terminator (ICEB 9.2).
    if "_" in word[:-1] and word.count("_") == 2:
        a = word.index("_")
        b = word.index("_", a + 1)
        return (translate_word(word[:a]) + ITALIC_WORD
                + translate_word(word[a + 1:b], caps_word_started) + translate_word(word[b + 1:]))
    caps_word =_is_all_caps_word(word) and not caps_word_started
    if caps_word:
        out += CAPITALS_WORD
    numeric = False               # inside a number (after the numeric indicator)
    chars = list(word)
    for i, ch in enumerate(chars):
        nxt = chars[i + 1] if i + 1 < len(chars) else ""
        prev = chars[i - 1] if i else ""
        if ch.isdigit():
            if not numeric:
                out.append(NUMERIC_INDICATOR)
                numeric = True
            out.append(DIGIT[ch])
        elif ch.isalpha() and ch.lower() in LETTER:
            if numeric and ch.lower() in "abcdefghij":
                out.append(GRADE1_SYMBOL)   # a-j straight after a digit would read as a digit
            numeric = False
            if ch.isupper() and not (caps_word or caps_word_started):
                out.append(CAPITAL_SIGN)
            out.append(LETTER[ch.lower()])
        elif ch in ".," and numeric and nxt.isdigit():
            out += PUNCT[ch]          # a decimal point or thousands comma keeps numeric mode
        elif ch == "'" or ch == "’" and prev.isalpha() and nxt.isalpha():
            numeric = False
            out += APOSTROPHE         # apostrophe inside a word ("don't")
        elif ch == '"':
            numeric = False
            out += STRAIGHT_QUOTE_OPEN if i == 0 else STRAIGHT_QUOTE_CLOSE
        elif ch in PUNCT:
            numeric = False
            out += PUNCT[ch]
        else:
            raise ValueError("no Grade 1 UEB rule for %r in %r" % (ch, word))
    return out


def translate_paragraph(text: str) -> list:
    """Translate a paragraph to a list of words, each a list of cells (spaces are implied).

    Runs of three or more all-capital words get one capitals-passage indicator and a
    terminator (ICEB 8.4) instead of a word indicator on each.
    """
    words = text.split()
    caps = [_is_all_caps_word(w) for w in words]
    result, i = [], 0
    while i < len(words):
        if caps[i]:
            j = i
            while j < len(words) and caps[j]:
                j += 1
            if j - i >= 3:                         # a passage: indicator on the first word
                for k in range(i, j):
                    w = translate_word(words[k], caps_word_started=True)
                    if k == i:
                        w = CAPITALS_PASSAGE + w
                    if k == j - 1:
                        w = w + CAPITALS_TERMINATOR
                    result.append(w)
                i = j
                continue
        result.append(translate_word(words[i]))
        i += 1
    return result


# --------------------------------------------------------------------------------------
# Page layout (BANA 2016).
# --------------------------------------------------------------------------------------

def number_cells(n: int) -> list:
    """A braille page number: numeric indicator plus digits (the NLS/BRF convention)."""
    return [NUMERIC_INDICATOR] + [DIGIT[d] for d in str(n)]


def center(cell_list, width):
    """A centered heading line: equal blanks both sides, the extra cell (if any) on the right."""
    pad = (width - len(cell_list)) // 2
    assert pad >= 3, "a centered heading needs 3+ blank cells each side (BANA 4.4.2)"
    return [0] * pad + list(cell_list)


def wrap(words, width, first_col, run_col):
    """Fill lines with whole words (BANA 1.10.1 forbids dividing words at line ends)."""
    lines, cur = [], [0] * first_col
    started = False
    for w in words:
        need = len(w) + (1 if started else 0)
        if started and len(cur) + need > width:
            lines.append(cur)
            cur, started = [0] * run_col, False
            need = len(w)
        if len(cur) + need > width:
            raise ValueError("word of %d cells does not fit a %d-cell line" % (len(w), width))
        cur = cur + ([0] if started else []) + list(w)
        started = True
    lines.append(cur)
    return lines


def layout(title, heading, paragraphs, width=40, height=25):
    """Lay out a book opening into pages of `height` lines of at most `width` cells.

    Page 1 carries the title centered on line 1 (BANA 1.8.1a), a blank line, the centered
    chapter heading, a blank line, then paragraphs with 3-1 margins.  The last line of each
    page holds the braille page number at the right margin.  Returns a list of pages; a
    page is a list of `height` lines; a line is a list of cells (no trailing blanks).
    """
    body = []                                       # (kind, cells) lines before pagination
    body.append(("text", center(translate_word_seq(title), width)))
    body.append(("blank", []))
    body.append(("head", center(translate_word_seq(heading), width)))
    body.append(("blank", []))
    for p in paragraphs:
        for line in wrap(translate_paragraph(p), width, first_col=2, run_col=0):
            body.append(("text", line))
    usable = height - 1                             # the last line is the page-number line
    pages, cur = [], []                             # cur holds (kind, line) pairs
    for kind, line in body:
        if kind == "blank" and not cur:
            continue                                # no blank line at the top of a page
        cur.append((kind, line))
        if len(cur) == usable:
            pages.append(cur)
            cur = []
    if cur:
        pages.append(cur)
    # A heading must be followed by text on its page (BANA 4.3.9).  This input never trips
    # it; the assertion stops a change of text from silently breaking the rule.
    for pg in pages:
        trailing = [k for k, _ in pg]
        while trailing and trailing[-1] == "blank":
            trailing.pop()
        assert not trailing or trailing[-1] != "head", "heading stranded at page end"
    finished = []
    for n, pg in enumerate(pages, 1):
        pg = [line for _, line in pg]
        pg = pg + [[] for _ in range(usable - len(pg))]
        num = number_cells(n)
        footer = [0] * (width - len(num)) + num
        assert footer.count(0) >= 3
        finished.append(pg + [footer])
    return finished


def translate_word_seq(text):
    """Translate a short phrase (spaces kept) to one cell list."""
    out = []
    for i, w in enumerate(translate_paragraph(text)):
        out += ([0] if i else []) + w
    return out


# --------------------------------------------------------------------------------------
# Writers.
# --------------------------------------------------------------------------------------

def trim(line):
    """Drop trailing blank cells."""
    line = list(line)
    while line and line[-1] == 0:
        line.pop()
    return line


def write_brf(pages) -> bytes:
    """BRF bytes: braille ASCII, CR LF after every line, a form feed between pages."""
    chunks = []
    for pg in pages:
        chunks.append("".join(to_ascii(trim(line)) + "\r\n" for line in pg))
    return "\f".join(chunks).encode("ascii")


def write_pef(pages, title, author, identifier, date, cols=40, rows=25) -> str:
    """A PEF 2008-1 document: one volume, one section, one page element per braille page.

    Rows hold Unicode braille only (the RELAX NG pattern is ([U+2800-U+28FF])*), so blank
    cells are U+2800 and a wholly blank row is an empty <row/>.
    """
    from xml.sax.saxutils import escape
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<pef version="2008-1" xmlns="http://www.daisy.org/ns/2008/pef">',
           '\t<head>',
           '\t\t<meta xmlns:dc="http://purl.org/dc/elements/1.1/">',
           '\t\t\t<dc:format>application/x-pef+xml</dc:format>',
           '\t\t\t<dc:identifier>%s</dc:identifier>' % escape(identifier),
           '\t\t\t<dc:title>%s</dc:title>' % escape(title),
           '\t\t\t<dc:creator>%s</dc:creator>' % escape(author),
           '\t\t\t<dc:date>%s</dc:date>' % date,
           '\t\t\t<dc:language>en</dc:language>',
           '\t\t</meta>',
           '\t</head>',
           '\t<body>',
           '\t\t<volume cols="%d" rows="%d" rowgap="0" duplex="false">' % (cols, rows),
           '\t\t\t<section>']
    for pg in pages:
        out.append('\t\t\t\t<page>')
        for line in pg:
            t = trim(line)
            out.append('\t\t\t\t\t<row>%s</row>' % to_unicode(t) if t else '\t\t\t\t\t<row/>')
        out.append('\t\t\t\t</page>')
    out += ['\t\t\t</section>', '\t\t</volume>', '\t</body>', '</pef>', '']
    return "\n".join(out)


# --------------------------------------------------------------------------------------
# Reader and Grade 1 decoder.
# --------------------------------------------------------------------------------------

def read_brf(data: bytes):
    """Parse BRF bytes to pages of lines of cells.  Accepts CR LF, LF, or CR line ends."""
    text = data.decode("ascii")
    pages = []
    for raw_page in text.split("\f"):
        lines = raw_page.replace("\r\n", "\n").replace("\r", "\n").split("\n")
        if lines and lines[-1] == "":
            lines.pop()                             # the text after the final line end
        pages.append([from_ascii(line) for line in lines])
    return pages


_UNICODE_PUNCT_BACK = {tuple(v): k for k, v in PUNCT.items() if k != "–"}
_LETTER_BACK = {v: k for k, v in LETTER.items()}
_DIGIT_BACK = {LETTER[l]: d for d, l in zip("1234567890", "abcdefghij")}


def decode_grade1(cell_list) -> str:
    """Back-translate Grade 1 UEB cells (blank = 0 = space) to print text.

    Handles capitals (letter, word, passage), numbers and the grade 1 indicator, the
    punctuation in PUNCT, apostrophes and italic word indicators.  It does not guess at
    contractions: that is the hard problem (see the report).
    """
    out, i, n = [], 0, len(cell_list)
    caps_word = caps_passage = False
    numeric = False
    italic_word = False
    c = cell_list

    def match(seq):
        return c[i:i + len(seq)] == seq

    while i < n:
        x = c[i]
        if x == 0:                                  # space ends word-level states
            if italic_word:                         # an italic word indicator ends at the space
                out.append("_")
                italic_word = False
            out.append(" ")
            caps_word = numeric = False
            i += 1
            continue
        if match(CAPITALS_PASSAGE):
            caps_passage = True
            i += 3
            continue
        if match(CAPITALS_TERMINATOR) and caps_passage:
            caps_passage = False
            i += 2
            continue
        if match(CAPITALS_WORD):
            caps_word = True
            i += 2
            continue
        if match(ITALIC_WORD):
            italic_word = True
            out.append("_")
            i += 2
            continue
        if x == NUMERIC_INDICATOR:
            numeric = True
            i += 1
            continue
        if numeric and x in _DIGIT_BACK:
            out.append(_DIGIT_BACK[x])
            i += 1
            continue
        if numeric and x in (cell("256"), cell("2")) and i + 1 < n and c[i + 1] in _DIGIT_BACK:
            out.append("." if x == cell("256") else ",")
            i += 1
            continue
        if x == GRADE1_SYMBOL and i + 1 < n and c[i + 1] in _LETTER_BACK:
            numeric = False                         # the indicator only ends numeric mode
            i += 1
            continue
        if x == CAPITAL_SIGN and i + 1 < n and c[i + 1] in _LETTER_BACK:
            out.append(_LETTER_BACK[c[i + 1]].upper())
            numeric = False
            i += 2
            continue
        if x in _LETTER_BACK:
            ch = _LETTER_BACK[x]
            out.append(ch.upper() if (caps_word or caps_passage) else ch)
            numeric = False
            i += 1
            continue
        if x == cell("3"):
            out.append("’")
            numeric = False
            i += 1
            continue
        for length in (3, 2, 1):                    # longest punctuation match first
            seq = tuple(c[i:i + length])
            if seq in _UNICODE_PUNCT_BACK:
                out.append(_UNICODE_PUNCT_BACK[seq])
                i += length
                numeric = False
                break
        else:
            raise ValueError("cannot decode cell %d at %d" % (x, i))
    if italic_word:
        out.append("_")
    return "".join(out)


def strip_page_numbers(pages):
    """Drop each page's last line (the braille page number) and join pages' text lines."""
    return [pg[:-1] for pg in pages]
