# Braille character codes outside North America (research, October 25, 2026)

Written by the `braillecodes` research agent (Claude Sonnet 5.5) for the brief `Scripts/agents/briefs/2026-10-24/braillecodes-research.md`. Branch `research/braille-codes`. No code was changed.

## Contents

- 1. Summary
- 2. The question, and one correction to the brief
- 3. How this was researched
- 4. Words: three things called "braille code"
- 5. Part 1: the codes in use
- 6. Part 2: where each exact table can be had
- 7. Part 3: how other software chooses a code, and whether one can be detected
- 8. Part 4: what TextMouth should build now
- 9. What I could not confirm
- Appendix A: the six-dot tables, cell by cell
- Appendix B: sources

Evidence words used below. "Documented" means a primary document, or the table's own header, says it. "Asserted" means one table's author says it and I found nothing to check it against. "Unconfirmed" means I found a table but no sign of use.

## 1. Summary

- "Braille code" hides two separate choices. The translation code (UEB, German, and so on) says what print a run of cells means. TextMouth already stores and offers it (`Book.brailleTable`, the Braille tab). The file character code says which character a BRF or BRL file writes for each cell. TextMouth has exactly one, fixed in `BrailleCells.asciiByDots`. This research is about the second.
- North American Braille ASCII is the code of nearly every braille file, whatever its language. Duxbury says "Most people use the North American encoding". liblouis makes `text_nabcc.dis` the display table of 33 table files, among them `en-ueb-chardefs.uti`, which both of TextMouth's UEB tables include (the second through `en-ueb-g1.ctb`). TextMouth's table is right: 64 of 64 against `en-us-brf.dis`, against `text_nabcc.dis`, and against Apple's own `apple_ascii.utb`, and its lowercase rule matches `text_nabcc.dis` on all 31 characters it covers.
- The one other seven-bit, six-dot code with real evidence is Eurobraille, for German-speaking Europe. It has an exact 64-cell table under LGPL 2.1 or later. Norway's generic embosser table is identical to it, and the Hungarian tables' author calls their output "eurobraille output". Read as North American Braille ASCII, 33 of the 64 characters of a Eurobraille file stand for the wrong cell (the digits, most punctuation, and the cells of ä, ö, ü, and ß), and no byte is invalid, so nothing refuses the file. TextMouth would show wrong text with no error.
- Norway's Braillo 047.01 six-dot table is case sensitive: lowercase `a`, `d`, `e`, `g` and others are cells of their own, not capitals. TextMouth's lowercase-reads-as-capital rule would misread it silently. So the reading rule belongs to each code, not to the reader.
- Every other national code I found is eight-dot and eight-bit (Danish Octo Braille in CP1252, Swedish 1996 and Norwegian in ISO-8859-1, French TBFR2007 in CP1252, Dutch 2020, Croatian, Czech, Lithuanian, UK). TextMouth refuses these today when a file holds a byte above 0x7F. They need eight-dot support through the reader, the analyzer, and the translation tables. They are not a first build.
- No program I found detects the seven-bit code. The PEF specification says that turning cells into ASCII braille is a one-to-one mapping, but "the opposite is not true, unless you know beforehand which locale it was produced for". Only three signals are certain: Unicode braille patterns, bytes above 0x7F, and PEF itself.
- Other software lets the reader choose. Duxbury's Save As offers "USA encoding" and "local encoding" as two BRF types. Embossers carry the table in a chip, firmware, or menu. liblouis tools take an explicit display table. PEF avoids the question by using Unicode patterns.
- Correction to the brief: the Mac's VoiceOver liblouis folder does hold display tables, 27 of its 485 files. See section 2.
- Recommendation. Build a small catalog of file codes now (identity, name, 64 characters, reading aliases), store a book's code as an id beside `brailleTable`, and offer it in the Braille tab, the Export dialog, and Book Information, following the Text Encoding pop-up. Ship three codes first: North American Braille ASCII, Eurobraille six-dot, and Unicode braille patterns. Leave Norwegian Braillo until a Norwegian reader confirms it, and leave all eight-bit national codes until TextMouth reads eight-dot braille. Do not guess among seven-bit codes.

## 2. The question, and one correction to the brief

The question: TextMouth reads and writes BRF and BRL in one table of 64 characters. Some countries' software and embossers store cells as other characters, so a file made that way holds valid ASCII and is read with the wrong cells. Others use eight-bit codes, which TextMouth refuses. The user (October 25) wants other braille books supported "if possible" and thinks a structure is easier to add now than later.

The correction. The brief says this Mac's VoiceOver liblouis tables "hold no `.dis` display tables". They do.

- Where: `/System/Library/ScreenReader/BrailleTables/LiblouisBrailleTranslator.brailletable/Contents/Resources/liblouis/tables` on macOS 26.3.1 (mac-folder).
- What: 27 of its 485 files end in `.dis`. They are the 26 display tables of liblouis 3.39.0, plus `ru-ru.dis`, which 3.39.0 does not have.
- Names: `bg`, `da-dk-octobraille`, `da-dk-octobraille_1993`, `de-de`, `de-eurobrl6`, `de-eurobrl6u`, `en-us-brf`, `es-new`, `es-old`, `hu-backtranslate-correction`, `nl-BE`, `nl-print`, `nl-unicode`, `no-no`, `no-no-braillo-047-01`, `no-no-generic`, `ru-brf`, `ru-letters`, `ru-ru`, `ru-unicode`, `se-se`, `text_nabcc`, `uni-text`, `unicode`, `unicode-without-blank`, `us-table`, `wordcx`.
- Same as upstream: I compared ten of them byte for byte with the same files in the liblouis master clone (`en-us-brf`, `text_nabcc`, `de-eurobrl6`, `de-eurobrl6u`, `no-no-braillo-047-01`, `bg`, `da-dk-octobraille`, `ru-brf`, `wordcx`, `nl-BE`). All ten are identical, and nine of them (all but `nl-BE`) are also identical in the `v3.39.0` tag.
- Why TextMouth's Mac catalog never shows them: it offers a file only when its header says `type: literary` and gives a display name and a language (`BrailleTableCatalog.table(at:source:)`), and a `.dis` file has no such header.
- What follows: do not read file codes from the Mac. A macOS update can change a file, and a book's bytes must read the same forever. The bundled folder already copies `Vendor/liblouis/tables` whole, so the tables TextMouth needs can be vendored from the 3.39.0 tarball (section 6).

Checked and true as the brief says: `Vendor/liblouis/tables` holds 17 files, and `text_nabcc.dis` is the only display table among them.

## 3. How this was researched

- 33 network operations (searches, fetches, downloads, and git fetches), a little over the brief's 30, because several first tries failed (listed below).
- Read directly:
  - liblouis: a sparse clone of `https://github.com/liblouis/liblouis` (master at commit `011cfb3b`, 2026-09-18, and tag `v3.39.0`, commit `2e775aca`, 2026-09-01). Nine key `.dis` files are identical in the two. The file lists are from `v3.39.0`. Header comments I quote are from master.
  - The PEF 1.0 specification, downloaded from `https://format.mtm.se/pef/10/` and read verbatim.
  - This Mac's liblouis folder, and TextMouth's own source and documents in this worktree.
- Read through the fetch tool, which condenses pages with a small model, so wording in these quotes may be slightly off: the Duxbury pages, the W3C Braille CSS draft, the DAISY problem statement, bskdl.org, the ViewPlus FAQ, Wikipedia, and the NVDA guide's introduction.
- Failed: the Index Braille manuals (both links returned 404), the PEF page on GitHub (404), `dotlessbraille.org` (no DNS answer, three tries), the NVDA guide's Braille section (the page is 405,000 characters and the fetch reached only the first 100,000).
- My own measurements, made with short Python scripts run with `python3 -I`: cell-by-cell comparison of display tables, a cross-check of tables against independent files, a count of which display table each Mac translation table reaches through its includes. The scripts and the downloads were in `/tmp` and were deleted at the end.
- Nothing under `~/.TextMouth` was read, copied, or written.

## 4. Words: three things called "braille code"

- The translation code: print to cells and back. UEB, EBAE, German, French, and so on, contracted or not. In liblouis it is a translation table (`.ctb`, `.utb`). In TextMouth it is `Book.brailleTable` and the Language, Braille code, and Contraction pop-ups.
- The file character code: cells to characters and back. Different programs call it different things.
  - liblouis: a display table (`.dis`).
  - Duxbury: an "encoding", as in "USA encoding" and "local encoding".
  - Embosser makers: a "braille table", often a chip or firmware setting.
  - PEF's specification: the "translation between ASCII characters and braille patterns", which "isn't" locale independent.
  - TextMouth: `BrailleCells.asciiByDots`.
- The cell width and the byte width: six dots or eight, seven bits or eight.
  - A six-dot, seven-bit code uses the 64 printable ASCII characters 0x20 to 0x5F, or an equivalent set.
  - An eight-dot code needs 256 cells, so it is eight-bit and tied to a code page (CP1252, ISO-8859-1, CP437).
  - Unicode braille patterns (U+2800 to U+28FF) cover both widths without a code page.
- The two codes are independent: a German translation table can be paired with North American characters, and an English one with Eurobraille characters. In practice they travel together by country, which is why one wrong choice is easy to make.

## 5. Part 1: the codes in use

### 5.1 The codes at a glance

Each line: proposed id, name, dots and bits, evidence, and whether an exact table exists. Details follow in 5.2 to 5.9. File extensions are in 5.9: I found no source that ties a code other than North American Braille ASCII to a particular extension.

- `ascii-na`, North American Braille ASCII. Six-dot, seven-bit. Documented, dominant. Exact table: yes, already in TextMouth.
- `unicode`, Unicode braille patterns in UTF-8. Six- or eight-dot. Documented (PEF, liblouis `unicode.dis`, eBraille). Exact table: yes, by definition (U+2800 plus the dots).
- `ascii-eurobraille`, Eurobraille six-dot (German, Austrian, Swiss; also Norwegian generic). Six-dot, seven-bit. Documented by a Swiss library for the blind, and asserted as widely used. Exact table: yes, 64 of 64, LGPL 2.1 or later.
- `ascii-braillo-no-047-01`, Norwegian Braillo six-dot. Six-dot, seven-bit, case sensitive. Asserted. Exact table: 63 of 63 non-blank cells, from one author.
- Danish Octo Braille, 2022 and 1993. Eight-dot, eight-bit (CP1252). Documented as a national standard. Exact table in liblouis: yes, 255 entries. Needs eight-dot support.
- Other eight-bit codes (Swedish, Norwegian, French, Dutch, Croatian, Czech, Lithuanian, UK, German eight-dot). Eight-dot, eight-bit. Documented as standards, unconfirmed as BRF contents. Exact tables: mostly only as translation tables, not as display tables.
- Spanish `es-old.dis` and `es-new.dis`. Eight-dot. Unconfirmed.
- Bulgarian `bg.dis`. Six-dot cells, but 13 of the 64 use characters above 0x7F. Unconfirmed.
- Asia: nothing confirmed.

### 5.2 North American Braille ASCII (`ascii-na`)

- What it is: 64 characters, 0x20 to 0x5F, one per six-dot cell, from about 1969 (wikipedia). It is the six-dot part of the North American Braille Computer Code, which defines all 95 printable ASCII characters in eight dots (liblouis: header of `text_nabcc.dis`).
- Extensions: `.brf`, `.brl`, and `.bra`. Orbit Reader 20's guide calls BRF and BRA "translated, formatted braille" and BRL "translated, unformatted braille" (formats-research). DAISY lists BRF, BRA, BRL, and PEF as the text-based braille formats in use (daisy-problem-statement, as summarized by the search tool). I found nothing for `.bfr`.
- How widespread:
  - Duxbury: "Most people use the North American encoding" (duxburysystems encoding page). Its Save As has a type called "Formatted braille, USA encoding (*.brf)" (duxbury-save-as).
  - Braillo 200 and 400 embossers sold through the US distributor are factory fitted with a chip for North American ASCII braille (duxbury-braillo).
  - The W3C Braille CSS draft calls the North American six-dot table "widely deployed" (w3c-braille-css).
  - liblouis gives `text_nabcc.dis` as the display table of 33 table files, among them the tables of Welsh (`cy-cy-g1.utb`), Irish (`ga-g1.utb`), Latvian (`Lv-Lv-g1.utb`), Maori (`mao-nz-g1.ctb`), Polish (`Pl-Pl-g1.utb`), Portuguese (`pt-pt-g1.utb`, `pt-comp6.utb`), Slovak (`sk-sk-g1.utb`), Slovenian (`sl-si-g1.utb`), Croatian (`hr-g1.ctb`), Swahili (`sw-ke-g1.utb`), Tamil (`ta-ta-g1.ctb`), Sinhala (`sin.utb`), Nepali (`ne.ctb`), Arabic and Hebrew eight-dot (`ar-ar-comp8.utb`, `he-IL-comp8.utb`), and Finnish (`fi-fi-8dot.ctb`). Counting by includes, 75 of the Mac's literary tables reach it.
  - The Russian BRF is the same code: `ru-brf.dis` includes `en-us-brf.dis` and adds only entries for the cells of the Russian tables that carry virtual dots 7 and 9, which it maps to the same characters, because "the Latin and Cyrillic alphabet are translated to the same dot patterns" (liblouis: comments in `ru-brf.dis`).
  - It is not uniform. A W3C draft says "there is no universally standard system of ASCII-braille equivalence used by all braille embossers", and the DAISY problem statement says the file formats in use "are often usable only in a specific region of the world due to differences in braille encoding and formatting".
- Lowercase: NABCC writes the six-dot letters in lowercase and gives capitals dot 7. TextMouth's rule (0x60 to 0x7E read as the character 0x20 below) agrees with `text_nabcc.dis` on all 31 characters. `us-table.dis` is a partial NABCC table (digits and punctuation, no letters); its 37 six-dot cells agree with `en-us-brf.dis` except in the same five punctuation cells, which it writes as `` ` ~ { | } ``, the characters TextMouth folds.
- Exact table: yes. See Appendix A.

### 5.3 Unicode braille patterns (`unicode`)

- What it is: one character U+2800 to U+28FF per cell, the low eight bits being the dots, dot 1 counting 1 (the Unicode block). It needs no code page, covers six and eight dots, and is what TextMouth uses inside.
- Where: PEF rows (pef-spec). eBraille, the DAISY standard of 2025, whose text is Unicode braille (formats-research). liblouis `unicode.dis`, a 256-entry table (liblouis). Plain `.txt` files from some tools (unconfirmed which).
- Why it is a code worth reading: it is the only one that can be detected with certainty (section 7.2), and it is exact by definition.
- Exact table: yes. Nothing to ship but the rule. U+2800 to U+283F is six-dot. U+2840 to U+28FF is eight-dot, which TextMouth refuses already for PEF ("This file is eight-dot braille, which TextMouth does not read").

### 5.4 Eurobraille, six-dot (`ascii-eurobraille`)

- What it is: 64 characters, with the letters in lowercase. In it `,` is dot 2, `.` is dot 3, `?` is dots 2-6, `1` is dots 1-6, `'` is dot 6. The letters, space, `#`, `&`, `-`, and `_` match North American Braille ASCII; 33 of the 64 cells do not.
- Who says it is in use:
  - The table's author, Christian Waldvogel of SBS, the Swiss library for the blind (2009): "This character mapping of 6-dot braille is widely being used in german speaking parts of europe" (liblouis: `de-eurobrl6.dis`).
  - `de-comp6.utb` calls the same code "a defacto standard as it is used at SBS to produce books for the German speaking readers" (liblouis). Its single-cell definitions agree with the display table on all 60 characters they share, letters and digits included, with none different.
  - liblouis's own German tables use it: `de-g0.utb` and `de-g0-detailed.utb` include `de-eurobrl6.dis` as their "default display table", and by includes so do the contracted German tables (6 on the Mac).
  - Norwegian: `no-no-generic.dis` is "useful for printing with embossers with German or Euro braille braille tables", and I checked that it equals `de-eurobrl6.dis` on all 63 cells it defines (liblouis, my measurement).
  - Hungarian: the author of `hu-hu-g1.ctb` refers to "eurobraille output", and all 13 entries of `hu-backtranslate-correction.dis` equal the Eurobraille characters (liblouis, my measurement).
  - bskdl.org, the site of a German-language braille committee, says that the standards observed in German-speaking countries go back to Eurobraille, developed in the 1980s, which "despite its name" is hardly found in other language areas. That page is about the eight-dot computer braille, and says that character representations differ between devices (bskdl).
  - Duxbury lists a "German" embosser encoding (duxbury-encoding). I could not see its contents.
- Variants:
  - `de-eurobrl6u.dis` is the same code written in capitals, "sometimes" used in Switzerland (liblouis). Its five punctuation characters are the lowercase ones minus 0x20 (`` ` { | } ~ `` become `@ [ \ ] ^`), so one table plus a reading alias covers both.
  - A comment in `de-eurobrl6.dis` says the standard's character for dots 4-5-6 is DEL (0x7F) and that the table uses `_` because it "seems more convenient and used more widely". A reader should accept 0x7F too.
- What I did not find: a sample BRF in this code, or a library saying it publishes BRF in it. Use is documented by table authors and by liblouis's pairings, not by files.
- Exact table: yes. 64 of 64, LGPL 2.1 or later. See Appendix A.

### 5.5 Norwegian Braillo, six-dot, table 047.01 (`ascii-braillo-no-047-01`)

- What it is: "Norwegian 6-dot display braille table for Braillo embossers", "Braillo Norway 6 dot, 047.01", by Lars Bjørndal, 2017 (liblouis: `no-no-braillo-047-01.dis`).
- Duxbury says Braillo embossers "are distributed worldwide with different internal chips for their various destinations" (duxbury-braillo). The 047.01 in the table's name looks like Norway's telephone code (47) and a variant number, but I found no Braillo manual that lists table numbers.
- It is case sensitive. Capitals are the plain letter cells. Fourteen lowercase letters (a, d, e, g, h, i, j, k, l, m, n, q, r, u) are other cells (a is dots 4-5, d is dots 1-4-5-6, and so on). Twelve lowercase letters, `<`, `>`, `{`, `}`, and `~` are not listed at all. TextMouth's fold would read `a` as dot 1.
- The file has 63 live entries (every non-blank cell once) and 16 commented-out alternatives. 77 of the 94 printable ASCII characters 33 to 126 are listed in one way or the other, so a real file may hold characters outside the 63 (the digits, for example, appear only in commented-out lines, with the same cells as the letters a to j).
- Evidence of use: one author's table. Asserted.
- Exact table: 63 non-blank cells, yes. It is safe to ship only after a Norwegian reader confirms it against a real file.

### 5.6 Eight-bit, eight-dot national codes

These are "computer braille": one cell per character of an eight-bit code page. liblouis holds them as translation tables (`comp8`), and for some also as display tables.

- Danish Octo Braille (2022, and 1993).
  - `da-dk-octobraille.dis` is the "Display table for Danish CP1252 Octo Braille (2022)", referring to "Den Danske Punktskrift 2022" by Det Danske Punktskriftsnævn, `https://www.blind.dk/punktskrift-2022` (liblouis). I did not read that page.
  - 255 entries. In the 2022 table 26 of the 64 six-dot cells use characters above 0x7F (dots 6 is 0x85, for example), and in the 1993 table 27 do, so even six-dot Danish text needs eight-bit bytes.
  - On the Mac, 20 Danish tables reach one of the two Octo Braille display tables, among them the six-dot literary tables `da-dk-g16`, `da-dk-g26`.
  - Documented as a standard. File use unconfirmed.
- Norwegian eight-dot: `no-no.dis` and `no-no-comp8.ctb`, ISO-8859-1, "based on the Offentlig Utvalg for Blindeskrift" (liblouis). 18 of the six-dot cells use characters above 0x7F. The 6-dot Norwegian tables on the Mac reach `no-no.dis`.
- Swedish: `sv-1996.ctb` is "the ISO-8859-1 compatible version of the Swedish 8-dot braille standard as it was defined by the Swedish Braille Authority (www.punktskriftsnamnden.se) on October 8, 1996". liblouis's maintainers marked its metadata as not verified. The only Swedish display table, `se-se.dis`, is marked obsolete.
- Dutch: `nl-comp8.utb`, "Dutch Computer Braille as used in Belgium and the Netherlands", version 2020.1, after "Achtpunts braillestandaard voor het Nederlandse taalgebied, versie 2020" by Braille Autoriteit. The three `nl-*.dis` files are not file codes: they are machinery for the Dutch tables' "virtual dots".
- French: `fr-bfu-comp8.utb` follows "TABLE BRAILLE INFORMATIQUE FRANÇAISE «TBFR2007»" of the Association Valentin Haüy and "is based on the cp1252 character set" (liblouis). `fr-bfu-comp6.utb` is a six-dot form with no display table.
- German eight-dot: `de-de-comp8.ctb` ("Eurobraille") says "not all of German 8-dot braille is properly standardized". bskdl.org cites DIN 32 982 (1994) and the technical report ISO/TR 11548 (2001) (bskdl). I could not read either.
- Croatian: `hr-comp8.utb`, "Croatian code page for computer 8-dot Braille alphabet ANSI-1250" from the Croatian Association of the Blind (liblouis).
- Czech: `cs-comp8.utb`, "based on the official Czech Braille Standard and Czech8.bwe (Window-Eyes Braille table)" (liblouis).
- Lithuanian: `lt-8dot.utb` follows a decree of 2011 that maps ISO-8859-13 to eight dots, and the table's header says "the Standard seems barely used, if at all" and that the six-dot `lt-6dot.utb` is the one in use (liblouis).
- United Kingdom: `en-gb-comp8.ctb`, cells numbered by CP437 (liblouis). UK six-dot BRF use NABCC as far as I can tell (`en-gb-g1.utb` includes `text_nabcc.dis`), but Duxbury also lists a separate "British" embosser encoding whose contents I could not see.
- Finnish, Italian, Polish, Portuguese, Hungarian: `fi-fi-8dot.ctb`, `it-it-comp8.utb`, `pl-pl-comp8.ctb`, `pt-pt-comp8.ctb`, `hu-hu-comp8.ctb`. The liblouis maintainers' notes on several say the metadata "hasn't been verified by the table author yet". The Italian six-dot `it-it-comp6.utb` is literary braille (Biblioteca di Monza code), not computer braille.
- Spanish: `es-old.dis` and `es-new.dis`, from odt2braille (DocArch, 2010), about 256 entries each, assigning even control codes to cells. Duxbury lists a "Spanish" embosser encoding. Unconfirmed.
- Bulgarian: `bg.dis` (2021). 64 cells, 13 of them with characters at 0xA7 to 0xF8. No other table includes it. Which code page, I could not tell.

### 5.7 Asia and other regions

- Japanese: liblouis has `ja-kantenji.utb`, `ja-kantenji-ucs2.utb`, `ja-rokutenkanji.utb`, with no display table. macOS ships its own Japanese kana braille in `AppleBrailleTranslator.brailletable` (`kanaToBraille.plist`, `BrailleToKana.plist`, `romajiToBraille.plist`) and `BrailleNBSC.brailletable`. I found nothing on a Japanese file or embosser code.
- Korean (`ko-*`) and Chinese (`zh-*`) tables have no display table either.
- South Asian languages in liblouis (`bh`, `kok`, `mwr`, `mun`, `ne`, `pi`, `sin`, `ta`, `dra`) use `text_nabcc.dis`.
- Thai (`th-comp8-backward.utb`), Vietnamese (`vi-cb8.utb`), Farsi (`fa-ir-comp8.ctb`), Coptic (`cop-eg-comp8.utb`), Belarusian (`bel-comp.utb`), and Slovenian (`sl-si-comp8.ctb`) have eight-dot computer tables; four Vietnamese literary tables reach `unicode.dis`.
- Conclusion: for Asia I found no file code other than NABCC and Unicode.

### 5.8 Russian and Ukrainian

`ru-letters.dis` ("Russian letters display codes", Igor Poretsky 2013) maps Latin letters to lowercase and Cyrillic ones to uppercase, `ru-unicode.dis` is by Bert Frees (2018), and `ru-ru.dis` (Mac only) cites ViewPlus's "Russian Braille Font Specification". I found no sign that any of them is a BRF code. A Russian BRF is North American Braille ASCII (see 5.2).

### 5.9 File extensions

- `.brf`: formatted pages, form feeds between pages. No official standard (Library of Congress, format description 551, quoted in formats-research).
- `.brl`: unformatted. `.bra`: formatted, per Orbit Reader 20's guide (formats-research).
- `.bfr`: not found in any source I searched.
- `.pef`: Unicode patterns in XML, recommended extension, media type `application/x-pef+xml` (pef-spec).
- Duxbury's own files are `.dxb` (braille with codes) and `.lbf` (refreshable braille) beside the two BRF types (duxbury-save-as).
- The extension says nothing about the code. I found no source that ties Eurobraille, Norwegian Braillo, or any eight-bit code to an extension, so a `.brf` from Germany and one from the United States can be told apart only by their bytes, and then only as far as section 7.2 says.

## 6. Part 2: where each exact table can be had

### 6.1 liblouis display tables (`.dis`)

- Where: `tables/*.dis` in the liblouis repository (26 files in the `v3.39.0` tag; the release tarball that `Vendor/liblouis` comes from is built from that tag, but I did not unpack it). Also on this Mac (27 files).
- Licence: every one of the 26 carries the header "GNU Lesser General Public License ... version 2.1 ... or (at your option) any later version" (I checked that none lacks "Lesser General Public"). The copyright holders are named in the headers: the BRLTTY Team, ViewPlus Technologies, JJB Software, SBS Zürich, Lars Bjørndal, Bue Vester-Andersen, DocArch, Bert Frees, and others. This is the licence of the liblouis TextMouth already bundles and carries (`Licenses/liblouis/COPYING.LESSER`, third-party-code).
- Format: `display <character> <dots>`, one entry per line; `\s` is the space, `\\` the backslash, `\xHHHH` a character by code; a dots field of 0 is the blank cell. An eight-dot cell lists dots 7 or 8. Some files carry virtual dots (the Dutch ones) or `include` another.
- The liblouis manual says a display character "must be in the range 0-255" and that `lou_translate -b` needs input that "must match the specified display table" (liblouis manual, `doc/liblouis.texi`). So liblouis's tools do not detect a code.

Status of each file, for a seven-bit, six-dot BRF:

- Complete, exact, six-dot, seven-bit:
  - `en-us-brf.dis`: 64 cells. North American Braille ASCII.
  - `de-eurobrl6.dis`: 64 cells. Eurobraille, lowercase.
  - `de-eurobrl6u.dis`: 64 cells. Eurobraille, capitals.
  - `no-no-generic.dis`: 63 cells (the blank is not listed), identical to Eurobraille on those; the file goes on with entries for eight-dot cells.
  - `no-no-braillo-047-01.dis`: 63 cells, case sensitive. See 5.5.
- Six-dot cells, but eight-bit characters:
  - `bg.dis`: 13 of 64 above 0x7F.
  - `da-dk-octobraille.dis` (2022) and `_1993`: 26 and 27 of 64 above 0x7F.
  - `no-no.dis`: 18 of 64 above 0x7F.
- Eight-dot:
  - `text_nabcc.dis`: 256 entries, Latin-1. NABCC.
  - `es-old.dis`, `es-new.dis`: about 256 entries each.
- Unicode patterns: `unicode.dis` (256 entries) and `unicode-without-blank.dis` (2 entries). Nothing to ship: the code is U+2800 plus the dots.
- Not file codes: `nl-BE.dis`, `nl-print.dis`, `nl-unicode.dis` (virtual-dot machinery), `hu-backtranslate-correction.dis` (13 entries, equal to Eurobraille's), `ru-letters.dis`, `ru-unicode.dis`, `ru-brf.dis` (includes NABCC), `us-table.dis` (37 six-dot cells of NABCC, no letters), `wordcx.dis` (a six-dot screen charset of Norwegian Word CX, after "Håndbok i punktskrift").
- Marked obsolete by liblouis ("This file is obsolete. Do not use!"): `de-de.dis`, `se-se.dis`, `uni-text.dis`.

### 6.2 Cross-checks I ran

- North American Braille ASCII: 64 of 64 equal between `en-us-brf.dis` and Apple's `apple_ascii.utb` (on this Mac). 64 of 64 equal between `en-us-brf.dis` and the six-dot part of `text_nabcc.dis`. TextMouth's lowercase rule (0x60 to 0x7E read as the character 0x20 below) gives the same six-dot cell as `text_nabcc.dis` for all 31 of those characters.
- Eurobraille: 60 of 60 printable ASCII characters that both `de-eurobrl6.dis` and SBS's own translation table `de-comp6.utb` (with the tables it includes) define have the same cell, with none different. The four characters only the display table defines are `"`, `$`, `'`, and `_`, which the translation table writes as two-cell sequences (4-4, 46-46, 6-6, and 4-456); the display table's cell is the repeated or last one in each.
- The capitals form of Eurobraille is the lowercase form with every character 0x60 to 0x7E replaced by the one 0x20 below it, in the letters and in all five punctuation cells.
- Which codes liblouis pairs with the Mac's literary tables (the first `.dis` each table reaches through its includes, my count): `text_nabcc.dis` for 75, no display table for 72, Danish Octo Braille for 18, Russian display tables for 13, German Eurobraille for 6, Norwegian `no-no.dis` for 5, Vietnamese `unicode.dis` for 4, Hungarian for 2, Dutch `nl-print.dis` for 1; 196 tables in all.

### 6.3 Other sources

- Embosser manuals. Duxbury lists embosser encodings: "British", "French", "German", "North American English", "Spanish" in `display.cpt`, and a "PUMA binary (transparent) code" in `pumavi.cpt` (duxbury-encoding). I did not obtain those files or their licence. ViewPlus Elite and Premier "come pre-loaded with many different braille translation tables", and a custom table is loaded through the printer's properties ("Download Custom Braille Table") from a file in `C:\Program Files\ViewPlus\Tiger\Common` (viewplus-faq). Braillo: no manual found. Index Braille: both manual links returned 404. Enabling Technologies: not searched. None of these gave a table I could read.
- Standards. DIN 32 982 (1994) and ISO/TR 11548 (2001) are cited by bskdl.org; I did not look for copies, and DIN and ISO documents are normally sold. The Danish, Dutch, Czech, French, Norwegian, and Lithuanian documents are cited in liblouis headers (URLs in Appendix B); I did not read them.
- BRLTTY's text tables are the origin of several liblouis computer-braille tables (the headers say "BRLTTY Text Table", "generated by ttbtest"). I did not read its repository or check its licence.
- Unicode: the braille patterns block, public.

### 6.4 What is shippable

- Exact, complete, licence compatible, and cross-checked:
  - North American Braille ASCII. Already in TextMouth.
  - Eurobraille six-dot (both written forms, with one table and the aliases). Cross-checked against SBS's own translation table.
  - Unicode braille patterns. No table.
- Exact for the cells it lists, one source, and use unconfirmed: Norwegian Braillo 047.01.
- Not yet shippable: anything eight-bit (needs eight-dot support and a code page decision), and `bg.dis` (code page unknown).
- Do not use: the obsolete files, and the files that are machinery for a translation table.
- On the licence: the safest compliant way is to vendor the unmodified `.dis` files from the 3.39.0 tarball into `Vendor/liblouis/tables` (the whole folder is already copied into the app, project.yml) and to list them in `docs/developer/third-party-code.md`. If the 64 characters are also written into Swift as `BrailleCells` does today, put the source file and its licence in a comment and test them against the vendored file. I am not giving legal advice.

## 7. Part 3: how other software chooses a code, and whether one can be detected

### 7.1 What others do

- Duxbury Braille Translator (DBT 12.5): File, Save As offers two BRF types.
  - "Formatted braille, USA encoding (*.brf)" "saves the file in the USA braille encoding (potentially different from your currently selected braille encoding)".
  - "Formatted braille, local encoding (*.brf)" "saves the file in the currently selected braille encoding (as selected in the Global Menu: Internationalization dialogue)" (duxbury-save-as).
  - So Duxbury has one global setting for the local encoding, the USA code always on hand, and no detection I could find. I did not find how DBT reads a BRF in another code.
  - Embosser setup has an "Encoding": "The encoding describes the relationship between the ASCII characters sent to the embosser and the desired braille output." "Some embossers (such as the Puma) cannot be set to the North American encoding." "A user could choose to use another encoding if they were using another software application which favored another encoding" (duxbury-encoding).
- Embossers: the table lives in the embosser (chip, firmware, or menu). Braillo: chips "for their various destinations" (duxbury-braillo). ViewPlus: pre-loaded tables and an upload of custom ones (viewplus-faq). Index: not obtained.
- liblouis tools: `lou_translate -d FILE` takes an explicit display table, and the manual says back-translation input "must match the specified display table". Many translation tables name their own default display table by `include` (section 6.2). No detection (liblouis manual).
- PEF avoids the problem. Its specification, section "Why Use Unicode Braille Patterns?" (read verbatim):
  - "Unicode and the Unicode braille patterns are locale independent. The translation between ASCII characters and braille patterns isn't. For example, common characters like .?()+$% and # render different braille patterns depending on locale. It is impossible to send an ASCII file for embossing on an embosser configured for another locale. This is a major issue for the non English speaking part of the world and it is the main reason for using Unicode braille patterns instead of ASCII characters."
  - "ASCII braille does not follow any known standard."
  - "Translating Unicode braille patterns into any ASCII based braille format is a simple one-to-one-mapping. However, the opposite is not true, unless you know beforehand which locale it was produced for." (pef-spec, public draft revised 12 September 2011, Joel Håkansson)
- W3C Braille CSS draft: "there is no universally standard system of ASCII-braille equivalence used by all braille embossers"; for eight-dot correspondences "have not been standardised, however, and vary from one country to another" (w3c-braille-css).
- DAISY, Braille File Formats, Problem Statement (August 17, 2022): "The formatting and braille code of the file are hardcoded", "the file is basically locked to a specific region of the world" (daisy-problem-statement).
- NVDA: uses liblouis for tables; the guide's introduction says it "supports braille codes for many languages, including contracted, uncontracted and computer braille codes", and its Braille settings have an Output Table and an Input Table. These choose a translation table, not a file code. I did not reach that section of the guide.
- VoiceOver, JAWS, BARD Mobile, notetakers (Orbit Reader, BrailleNote, Mantis, Brailliant), BrailleBlaster: not researched beyond a search summary of the BrailleBlaster 2.1 manual (its View Braille setting shows simulated braille or ASCII, nothing about a file code). My understanding is that a screen reader sends cells to a display, so no file code arises for it. That is unconfirmed.

### 7.2 Can a code be detected from a file?

Nothing I found does it, and the PEF specification says that turning ASCII braille back into cells is not a fixed mapping unless the locale is known. My measurements agree. Signals, with how far each can be trusted:

- Certain:
  - A UTF-8 file whose non-blank characters are U+2800 to U+28FF (bytes `E2 A0` to `E2 A3`, then `80` to `BF`) is Unicode braille.
  - A UTF-16 or UTF-32 byte order mark with braille patterns after it.
  - A PEF file (already detected by its XML).
- Certain that it is not a seven-bit code, and nothing more: a byte above 0x7F that is not part of valid UTF-8. Then the code is an eight-bit one, but which of CP1252, ISO-8859-1, CP437, ANSI-1250 cannot be told from the bytes alone. A file's translation table helps only a little: liblouis pairs Danish tables with Octo Braille, for example.
- Certain that it is not a seven-bit braille text: control characters other than CR, LF, form feed, tab, and Ctrl-Z. TextMouth already refuses these. (In some eight-bit codes control bytes are cells; `es-old.dis` gives 0x0A to dot 1.)
- A hint and no more: a byte in 0x60 to 0x7E that is not a letter (`` ` { | } ~ ``). A German Eurobraille text holds these often (ä is `` ` `` and ß is `~`, from the cells in `de-chardefs6.cti`). A canonical North American BRF never holds them. But some tools write North American BRF in lowercase and use these five for dots 4, 4-5, 2-4-6, 1-2-5-6, and 1-2-4-5-6, so the hint would fire wrongly on them.
- A hint and no more: letters of both cases in one file. In eight-dot NABCC a capital is the small letter plus dot 7, and in Norwegian Braillo the cases are different cells. TextMouth's fold hides both.
- Not enough on its own: letter frequency. The 26 letters have the same cells in North American Braille ASCII and Eurobraille, so a language can be guessed from letters while the code stays unknown.
- Strong but costly and fuzzy: translate a sample under each candidate code with the book's translation table, and score how many results are words. It runs liblouis in the helper once per candidate, and it can only be as good as the table. I do not recommend it for the first build.
- Headers: a BRF has none. A PEF has `dc:language`, which names a language, not a code. I found no BRF header convention.

What a wrong code costs, as a concrete example. In Eurobraille the character `?` is the cell with dots 2-6. North American Braille ASCII reads `?` as dots 1-4-5-6, the cell English braille writes as "th" (Duxbury's own page: "in the North American encoding, the 'th' sign is represented by a question mark"). So read as North American, each question mark of a Eurobraille file becomes dots 1-4-5-6, whatever the translation table then makes of that cell. The two tables agree on 31 of 64 cells (space, the 26 letters, `#`, `&`, `-`, `_`) and differ on 33. The letters read right, so the text looks plausible, and nothing is invalid, so nothing is refused.

## 8. Part 4: what TextMouth should build now

### 8.1 Principles

- Keep the two codes apart. The file character code is stored beside `brailleTable`, never inside it.
- A book that records no code is North American Braille ASCII, as every book so far. That default makes the record side cheap to add later. What is costly to retrofit is the plumbing, so build that now.
- A code is data in one catalog. Adding one is an entry, a test, and a line in the docs, not a new branch in the reader.
- Reading rules belong to the code. The lowercase fold is NABCC's, the capitals fold is Eurobraille's, and Norwegian Braillo has neither.
- An id this build lacks is refused by name and never read as another code, as an unknown table is (`adding-books.md`: "TextMouth has no braille table named...").
- Never guess among seven-bit codes. Certain signals only.
- Follow the Text Encoding pop-up (`TextEncodingChoiceModel`, `TextEncodingRecord`, `TextEncodingChoices`, `readTextAgain`), including its accessibility wording and its re-read flow.

### 8.2 A code's identity

A small value type, a catalog, and the family of the code.

- Fields:
  - `id`: lowercase, permanent, never reused (`ascii-na`, `ascii-eurobraille`, `unicode`). A corrected table gets a new id.
  - `name`: what the pop-ups list ("North American Braille ASCII", "Eurobraille, six-dot (German-speaking countries)", "Unicode braille patterns").
  - `summary`: one sentence for the hint, such as where the code is used.
  - The kind of code: `.ascii` (sevenBit, six-dot, 64 bytes plus reading aliases), `.unicodePatterns`, and later `.eightBit` (a 256-entry table, eight-dot).
  - For `.ascii`: the 64 bytes in cell order (the same order as `BrailleCells.asciiByDots`), and `readingAliases`, a map from an extra byte to the byte it is read as.
- Reading aliases per code: NABCC `0x60...0x7E` to `0x40...0x5E` (today's rule); Eurobraille `0x41...0x5A` to `0x61...0x7A`, `@ [ \ ] ^` to `` ` { | } ~ ``, and DEL to `_`; Norwegian Braillo none.
- Functions: `dots(forByte:)` returns the cell's dots (the byte `BrailleFilePages` stores) or nil, and `byte(forDots:)` returns what the code writes.
- A sketch, not final code:

```swift
/// How a BRF or BRL file writes each braille cell as a character: one entry of the
/// catalog of codes. A sketch of the shape; the final names are the implementer's.
struct BrailleFileCode: Identifiable, Hashable, Sendable {
    /// Permanent: stored in books, records, removal markers, and config.json.
    let id: String
    /// The name the pop-ups list, such as "Eurobraille, six-dot".
    let name: String
    /// The byte written for each six-dot cell, in the order of the cells' dot values
    /// 0 to 63 (the order of `BrailleCells.asciiByDots`).
    let bytes: [UInt8]
    /// Bytes besides `bytes` that a file may hold, each read as the byte it maps to:
    /// NABCC's lowercase, Eurobraille's capitals and DEL.
    let readingAliases: [UInt8: UInt8]

    /// The dots of the cell `byte` stands for (dot 1 counts 1), or nil for no cell.
    func dots(forByte byte: UInt8) -> UInt8?
    /// The byte this code writes for a six-dot cell.
    func byte(forDots dots: UInt8) -> UInt8
}
```

- `BrailleCells` keeps what is about Unicode patterns (blank, `isPattern`, `usesEightDots`, `sixDotPart`, `escapeBackslash`, `dotsInWords`, `spaced`). The table and the two conversion functions move to the code type, with North American Braille ASCII as the first catalog entry and the default.

### 8.3 Where the reader chooses

- The Braille tab of Settings: one more pop-up beside Language, Braille code, and Contraction. A suggested label is "Braille File Characters" (the user chooses the words). Hint: "How a BRF or BRL file writes each braille cell as a character. Most files use North American Braille ASCII." Default: North American Braille ASCII. config.json key: `brailleFileCode`. The caption already says a change applies to books imported from then on and a book keeps its code; it needs one more clause.
- Import: the setting is read once for the import, as `BraillePreferences.importTable()` is, and recorded on the book. PEF books record none.
- The Export dialog: for BRF only, a pop-up beside "Line ends", preset from the Settings value. PEF ignores it, since it is always Unicode. This is also the right advice for sharing a book with a reader elsewhere: export a PEF, which needs no code.
- Book Information, for a braille book that is a BRF or BRL (not a PEF): a pop-up button row "Braille File Characters" after "Braille Code". VoiceOver would say its value first: "North American Braille ASCII, Braille File Characters". Choosing another asks first in an alert and then reads the file again, with the same flow the Text Encoding pop-up uses. Three differences:
  - There is no "Automatic" and no "guessed", since nothing is guessed. Items are the codes. If a certain signal ever picks a code at import (Unicode), the row names it plainly.
  - A seven-bit code never says "bytes that are not valid" about a wrong choice, because every printable ASCII byte is valid in every code. The alert should say so: "Nothing checks that this is the right choice. If numbers and punctuation sound wrong, choose another."
  - A refusal when the file holds a byte the chosen code has no cell for (a control character, or a byte above 0x7F in a seven-bit code), in the sentence form TextMouth already uses.
- Speak Full Info: "Braille characters: North American Braille ASCII." after the braille code sentence.
- Optional and later: when the chosen translation table is one liblouis pairs with another code (the German tables with Eurobraille), the Braille tab can say "German braille files are often written in Eurobraille; choose it above if numbers and punctuation come out wrong". It is a hint, not a switch.

### 8.4 What a book records

- One optional field, `brailleFileCode: String?`, with the same triple as `brailleTable`: the library row (`Book`), the package record (`BookInfo.metadata`), and the removal marker (`RemovedFromLibraryMarker`).
- Nil means `ascii-na`, as `brailleTable` nil means the default table. Older records and older builds therefore keep working: an older TextMouth ignores the key and reads North American Braille ASCII.
- The rule `TextEncodingRecord.standing(row:recorded:)` (the record wins over a lagging row) should be copied, because the package record is the copy an older build or another Mac cannot drop.
- No "source" field in the first build. The text encoding added one (`textEncodingSource`) because it records guesses. If detection is ever added, add the field then, optional and absent for an import, as that was.
- Do not record the table's content or a version. The ids are permanent and a shipped table never changes.
- Every place that carries `brailleTable` carries the code. A grep finds 15 files: `Book`, `BookInfo`, `RemovedFromLibraryMarker`, `LibraryInfoWording`, `BookParser`, `BrailleBookReader`, `MarkdownCacheService`, `BookContentAnalysisService`, `FileImportService`, `FileImportService+Packages`, `SettingsViewModel`, `ConfigService`, `BrailleTableCatalog` (where `BraillePreferences` lives), `BrailleSettingsView`, and `BrailleExportOptionsView`.

### 8.5 Detection

- First build: certain signals only.
  - Unicode braille patterns: an import of a `.brf` or `.brl` whose characters are U+2800 to U+28FF is read as `unicode` and recorded so.
  - Bytes above 0x7F that are not valid UTF-8: keep refusing, but say what the file may be: "This file looks like eight-bit computer braille, which TextMouth does not read." (the current sentence says only "holds the byte 0xE9, which is not braille ASCII").
  - Everything else: the Settings code, with no guess.
- Later and optional: a hint after import when a file holds `` ` { | } ~ `` bytes and the code was North American, in the import's report, never a switch. Expect false positives from lowercase writers.
- Not recommended: dictionary scoring across candidate codes.

### 8.6 Which codes to ship first, and with what evidence

- First build, three codes:
  - `ascii-na`: documented everywhere, exact, already built.
  - `ascii-eurobraille`: the only other seven-bit six-dot code with several independent pointers (a Swiss library for the blind's own table and book production, liblouis's German and Norwegian pairings, the Hungarian remark, bskdl.org). Exact, 64 of 64, cross-checked against a second SBS table. It exercises the structure's hard parts: lowercase letters, reading aliases in the other direction, DEL. It is missing a real sample BRF, so ask a German-speaking reader for one.
  - `unicode`: exact by definition, certainly detectable, and it proves the structure holds two kinds of code before a third arrives.
- Next, when a Norwegian reader or library can confirm it against a real Braillo file: `ascii-braillo-no-047-01`. It is the test that the reading rule really is per code.
- After TextMouth reads eight-dot braille: Danish Octo Braille first (an official 2022 standard with an exact display table), then Swedish, Norwegian, French, Dutch.
- Not recommended: the obsolete tables, the translation-table machinery, Lithuanian eight-dot, Spanish `es-old.dis` and `es-new.dis`, Bulgarian until its code page is known.

### 8.7 What changes, file by file

- `TextMouth/Parsers/BrailleCells.swift`: the table (`asciiByDots`, `dotsByASCII`) and `cell(forASCII:)` and `ascii(for:)` move into the code type; keep thin North American forwards only where a mnemonic is wanted (below). Today there are exactly three production call sites of the table: `BrailleFileReader.swift:386`, `BraillePageAnalyzer.swift:892`, and `BrailleFileWriter.swift:99`.
- `TextMouth/Parsers/BrailleFileReader.swift`: `read(_:as:)` and `pages(fromASCII:kind:)` take a code (default North American). `ASCIIScanner.take` asks the code for the cell. The refusal `notBrailleASCII` keeps today's words for the default code and names any other ("...which is not in Eurobraille"), and keeps its other forms. A Unicode path decodes UTF-8 scalars, takes U+2800 to U+283F, refuses U+2840 to U+28FF with the existing eight-dot sentence, and still treats CR, LF, form feed, tab, and the byte order mark as today.
- `TextMouth/Services/BrailleFileWriter.swift`: `brf(pages:lineEnd:)` takes a code. The eight-dot rules and the escape backslash (U+2873 written as the six-dot ⠳) act on cells before the code maps them, so they do not change. The doc comment "The result is ASCII only" becomes true of seven-bit codes only; the Unicode code writes UTF-8. `BrailleDocumentWriter` gets a `fileCode` option beside `lineEnd`.
- `TextMouth/Parsers/BraillePageAnalyzer.swift`: nothing in the layout reading depends on the code. It works on dots (`numberSign: 0x3C`, the ten digit cells), so a Eurobraille book gets the same pages, headings, and numbers. One function does depend on the table: `printLabel(of:)` calls `BrailleCells.ascii(for:)` only to name dot patterns (`#`, `,`, `;`, `A` to `Z`). That must stay the North American table whatever the book's code is, and should be renamed so no one passes the book's code to it. Add a test that two books with the same cells in different codes have the same labels. The number convention (number sign, then a to j) is an English and Western one; a book in a code without it finds no numbers and falls back to the page's place, which the analyzer already does.
- Book record and library: `Book.brailleFileCode`, `BookInfo.metadata`, `RemovedFromLibraryMarker`, `BookParser.parse(...)` and the Markdown cache rebuild (`MarkdownCacheService`), the content analysis (`BookContentAnalysisService`), import (`FileImportService`, `FileImportService+Packages`).
- Settings: `BraillePreferences.fileCode` (a `StoredPreference<String>` as `table` is), `SettingsViewModel`, `ConfigService` (key `brailleFileCode`), `BrailleSettingsView`.
- Export: `BrailleExportOptions`, `BrailleExportOptionsView`, `BrailleExportWriters`.
- Book Information: `LibrarySheetViews` (the row), a model like `TextEncodingChoiceModel` (the two should share what they can, under the project's DRY rule), `LibraryViewModel` re-read flow, `LibraryInfoWording` (Speak Full Info).
- Vendor: add `en-us-brf.dis`, `de-eurobrl6.dis`, and `de-eurobrl6u.dis` from the 3.39.0 release (they are in its tag), unchanged, for the tests; `docs/developer/third-party-code.md` lists them. `text_nabcc.dis` is already there.
- Docs: `adding-books.md` (refusal wording), `what-textmouth-reads.md`, `settings.md`, `exporting-books.md`, `library-window.md`, `where-your-library-lives.md`, `config-json.md`, `changelog.md`, and the architecture pages for imports and exports.
- Tests (each code): 64 distinct bytes; every cell round trips; aliases read as stated; control characters and bytes above 0x7F are no cell; a test that reads the vendored `.dis` and compares 64 of 64 (as `BrailleCells` already claims for `en-us-brf.dis`); the BRF-sample-equals-PEF-sample test for each code (convert the sample's cells to the code's bytes and back; this proves round trips, not real use, so a real sample file is still wanted); record migration (absent key reads as North American, unknown id is refused by name and kept); settings and config.json round trip; the Book Information model.

### 8.8 Order of work

Small commits, each one thing:

1. The code type, the catalog with North American Braille ASCII, and its tests; `BrailleCells` forwards to it. No behaviour change.
2. The reader takes a code (default North American). The refusal keeps today's words for North American Braille ASCII and names the code for any other.
3. The writer takes a code.
4. The analyzer's label function uses the North American table by name; the same-labels test.
5. Eurobraille, with the vendored `.dis` test.
6. Unicode braille patterns: the reading path and the certain detection.
7. The record on `Book`, `BookInfo`, and the marker, with import and rebuild plumbing and migration tests.
8. The Braille setting and config.json, and the Export pop-up.
9. The Book Information pop-up and the re-read.
10. Documents and the changelog.

The first four change no behaviour, so they can merge early and carry the risk down.

### 8.9 Edge cases and risks

- A wrong choice is silent. For a blind reader the only sign is text that sounds wrong. A later improvement worth considering: let the confirmation alert read the first line of the new reading before committing.
- Case: never fold the case before looking up the code's own table. The fold is data.
- DEL (0x7F) is a cell in Eurobraille, and an error in North American Braille ASCII today. Per code.
- Tab is one blank cell in a seven-bit code. In eight-bit codes control bytes may be cells (`es-old.dis` assigns 0x0A to dot 1), so the structural bytes are the code's business too, when eight-bit arrives.
- The page analyzer's blank-row and margin logic works on cells, but a code whose blank cell is not the space (none found among the seven-bit ones; `no-no-braillo-047-01.dis` simply does not list it) needs a defined blank.
- Exporting in Eurobraille makes a file only German-style embossers and software read as written. Say so in the pop-up's hint, and point to PEF.
- Compatibility: an older TextMouth that opens a library holding a Eurobraille book ignores the key and, if it rebuilds the book's text, reads it as North American. The version policy (PATCH for small non-breaking features, MINOR for non-backward-compatible changes) leaves this a decision for the user; the text encoding precedent treated it as non-breaking.
- A dropped key: the triple of row, record, and marker, and the `standing` rule, guard it as they do for the text encoding.
- Accessibility: the pop-up reuses the Text Encoding pop-up's tested wording, value first. No new color or visual-only cue.
- The Mac's own `.dis` files must never be read for a book's code (section 2).

### 8.10 Questions for the user

- The label: "Braille File Characters" is a suggestion. Alternatives: "Braille Encoding" (as Duxbury says) or "Cell Characters". It must not be confused with "Braille Code", which names the translation.
- Whether the first build should include Unicode braille patterns. I recommend yes.
- Whether Eurobraille should wait for a real sample file from a German-speaking reader. I recommend building it, and asking for a sample to test with.
- Whether to keep "no guess" for seven-bit codes. I recommend yes.
- The version: PATCH or MINOR (section 8.9, compatibility).

## 9. What I could not confirm

- Embosser makers' manuals. Index Braille: both manual links gave 404. Braillo: no manual found, only Duxbury's note about chips and liblouis's table name. Enabling Technologies: not searched. ViewPlus: only a FAQ. Duxbury's `display.cpt`: names seen, contents not.
- That German, Austrian, or Swiss BRF files in circulation are written in Eurobraille. The table's author and liblouis's pairings say so; I saw no file and no library statement.
- That Norwegian BRF files are in Braillo 047.01 or in Eurobraille. Both appear in liblouis; neither was checked against a file or a Braillo document.
- The contents of Duxbury's British, French, German, Spanish encodings.
- Whether the UK writes BRF in anything but North American Braille ASCII.
- The standards: DIN 32 982, ISO/TR 11548, the Danish 2022 standard, the Dutch 2020 standard, the French TBFR2007, the Czech standard, the Lithuanian decree, the Croatian code page. I read only what liblouis says of them.
- `.bfr`: no source. `.bra` and `.brl`: only second-hand.
- Anything for Japan, Korea, China, Thailand, or India beyond liblouis's own tables and macOS's bundles.
- How VoiceOver, JAWS, BARD Mobile, BrailleBlaster, and notetakers choose or detect a code. BrailleBlaster's documentation was seen only in a search summary. NVDA's Braille section was not reached.
- Whether any program detects the seven-bit code. I found none; absence is not proof.
- How many real files use any non-North-American code. I found no statistics.
- Quotes taken through the fetch tool may be condensed. The liblouis, PEF, and Mac-folder quotes are verbatim.

## Appendix A: the six-dot tables, cell by cell

Each string below is the characters of cells 1 to 63, in the order of the cells' dot values (dot 1 counts 1, dot 6 counts 32), the order of `BrailleCells.asciiByDots`. Cell 0, the blank cell, is the space in the first three; the Norwegian file does not list it. The strings come from the `display` lines of the named file with dots 7 and 8 left out, read by my script; the file is the source.

North American Braille ASCII, from `en-us-brf.dis` (equal to the current `BrailleCells.asciiByDots` after its leading space):

```
A1B'K2L@CIF/MSP"E3H9O6R^DJG>NTQ,*5<-U8V.%[$+X!&;:4\0Z7(_?W]#Y)=
```

Eurobraille, lowercase, from `de-eurobrl6.dis` (SBS Zürich, 2009):

```
a,b.k;l"cif|msp!e:h*o+r>djg`ntq'1?2-u(v$3960x~&<5/8)z={_4w7#y}%
```

Eurobraille, capitals, from `de-eurobrl6u.dis`:

```
A,B.K;L"CIF\MSP!E:H*O+R>DJG@NTQ'1?2-U(V$3960X^&<5/8)Z=[_4W7#Y]%
```

Norwegian Braillo 047.01, from `no-no-braillo-047-01.dis` (case sensitive; its file does not list the blank):

```
A,B.K;L`CIF/MSP'E:H@O+RaDJG[NTQ*]?r-U"Vqm\h&Xli_e%u$Z=k|dWg#Ynj
```

Facts about these strings, from my comparison:

- Eurobraille (either form) and North American Braille ASCII agree on 31 of 64 cells (case folded): the blank, the 26 letters, `#` (dots 3-4-5-6), `&` (dots 1-2-3-4-6), `-` (dots 3-6), and `_` (dots 4-5-6). The other 33 differ.
- Norwegian Braillo and North American Braille ASCII differ on 34 of the 63 cells the Norwegian table defines (compared with case folded; the folding hides no difference here).
- The five characters by which Eurobraille capitals differ from lowercase, and North American lowercase from capitals, are the same five pairs: `` ` `` and `@`, `~` and `^`, `{` and `[`, `|` and `\`, `}` and `]`.
- The three liblouis files `bg.dis`, `da-dk-octobraille.dis`, and `no-no.dis` use characters above 0x7F for six-dot cells (13, 26, and 18 cells), so they cannot be written as strings of printable ASCII.

## Appendix B: sources

Read directly:

- liblouis: `https://github.com/liblouis/liblouis`. Tag `v3.39.0` (commit `2e775aca674cd2910e272eed7736acceb4c2e4a2`, 2026-09-01) and master (commit `011cfb3b5868f9e0a63092d5cfa39b0caf57fe21`, 2026-09-18). Files in `tables/` named in the text, `tables/README`, and `doc/liblouis.texi` (the `display` opcode; the `lou_translate --display-table` option).
- mac-folder: `/System/Library/ScreenReader/BrailleTables/LiblouisBrailleTranslator.brailletable/Contents/Resources/liblouis/tables` (485 files, macOS 26.3.1), and the `AppleBrailleTranslator`, `BrailleNBSC`, `Duxbury`, and `Rhine` bundles beside it.
- pef-spec: "PEF 1.0 - Portable Embosser Format", public draft revised 12 September 2011, author Joel Håkansson, hosted by MTM, `https://format.mtm.se/pef/10/`.
- textmouth-code: `TextMouth/Parsers/BrailleCells.swift`, `BrailleFileReader.swift`, `BraillePageAnalyzer.swift`; `TextMouth/Services/BrailleFileWriter.swift`, `BrailleDocumentWriter.swift`; `TextMouth/Models/Book.swift`, `BookInfo.swift`, `BrailleTableCatalog.swift`, `TextEncodingRecord.swift`, `TextEncodingChoice.swift`; `TextMouth/ViewModels/TextEncodingChoiceModel.swift`; `docs/user/library-window.md`, `settings.md`, `what-textmouth-reads.md`; `docs/developer/third-party-code.md`; `project.yml`; `Vendor/liblouis/tables`.
- formats-research: `FORMATS-RESEARCH-2026-10-17.md` in this repository, section 3.1 (BRF, BRL, BRA, PEF, eBraille; Library of Congress format description 551; Orbit Reader 20's guide).

Read through the fetch tool (condensed):

- duxbury-encoding: `https://www.duxburysystems.com/documentation/dbt12.4/embossers_and_embossing/Codes/embosser_codes/Encoding.htm`
- duxbury-save-as: `https://www.duxburysystems.com/documentation/dbt12.5/the_menus/MENU_FILE/file_save_as.htm`
- duxbury-braillo: `https://www.duxburysystems.com/documentation/dbt12.6/embossers_and_embossing/Embossers_elt_info/ztech_Braillo_200.htm`
- w3c-braille-css: `https://www.w3.org/WAI/PF/braillecss.html` (a draft; no date or author on the page I read)
- daisy-problem-statement: `https://daisy.org/?p=5368`, "Braille File Formats - Problem Statement", August 17, 2022
- bskdl: `http://www.bskdl.org/braillesysteme.html`, section "Computerbrailleschriften", page last changed 7 May 2023
- viewplus-faq: `https://support.viewplus.com/kb/faq.php?id=249`
- wikipedia: `https://en.wikipedia.org/wiki/Braille_ASCII`
- NVDA: `https://download.nvaccess.org/documentation/userGuide.html` (introduction only)

Cited by liblouis headers, not read by me:

- Danish braille 2022: `https://www.blind.dk/punktskrift-2022`
- Dutch eight-dot standard 2020: `http://liblouis.io/braille-specs/dutch/`
- Norwegian "Håndbok i punktskrift": `http://liblouis.io/braille-specs/norwegian/`
- French TBFR2007: `https://www.avh.asso.fr/sites/default/files/table_braille_informatique_tbfr2007_final_0.doc`
- Czech standard: `http://teiresias.muni.cz/czbraille8/?strana=norma`
- Lithuanian decree: `https://www.e-tar.lt/portal/lt/legalAct/TAR.443D667CA047`
- German computer braille: `http://www.bskdl.org/braillesysteme.html#computer` and `http://braille.ch/computer.htm`
- Swedish Braille Authority: `www.punktskriftsnamnden.se`

My measurements: cell-by-cell comparison of `en-us-brf.dis`, `de-eurobrl6.dis`, `de-eurobrl6u.dis`, `no-no-braillo-047-01.dis`, `bg.dis`, `text_nabcc.dis`, `da-dk-octobraille.dis`, `no-no.dis`, `no-no-generic.dis`, `us-table.dis`, `hu-backtranslate-correction.dis`; the cross-check of `en-us-brf.dis` against `apple_ascii.utb` and `text_nabcc.dis`, and of `de-eurobrl6.dis` against `de-comp6.utb`; the count of the display table each Mac translation table reaches through includes. The scripts were temporary and deleted.
