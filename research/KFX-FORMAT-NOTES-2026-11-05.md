# KFX format notes (2026-11-05)

Written by the `kfxstudy` research agent. Facts about Amazon's KFX file format, in the author's own words, for a later implementer who has not opened the GPL plugin. There is no code and no pseudocode here. Symbol numbers and their meanings are facts about the format, so they are given freely.

How sure each statement is: **[V]** checked by reading a real container (the ebook-rs Alice sample, see part 12), **[P]** read in the plugin and not checked against a file, **[W]** from a public web source, **[?]** not verified. Almost everything in parts 4, 6, 7, 8 and 9 marked **[V]** was checked against one file that was written by a third-party converter (boko), not by Amazon. Treat the byte layouts as solid and the "what Amazon really emits" parts as likely, not proven.

## Summary (to read aloud)

1. KFX is a binary container ("CONT") of numbered fragments. Each fragment is Amazon Ion binary. Nothing is compressed in any file the plugin handles.
2. Amazon-sold KFX books are protected: the main file starts with the eight bytes EA 44 52 4D 49 4F 4E EE ("DRMION") instead of "CONT", with a voucher file beside it. A reader refuses these from the first eight bytes and never decrypts.
3. A DRM-free KFX starts with "CONT", version 2 (older ones version 1). It has an 18-byte header, a small Ion "container info" struct, an entity table of 24-byte rows, a local symbol table, and the entities themselves.
4. Symbols are numbers. The shared table "YJ_symbols" is imported, and a reader only needs the numbers (the plugin's own catalogue holds no names, only numbers). Names are needed only for the book's local symbols, which come from the file.
5. The text lives in content fragments (`$145`, lists of strings). Storylines (`$259`) hold the structure and point into the text by name and index. Sections (`$260`) point at storylines. The reading order is a list of section names in document data (`$538`).
6. Text offsets in style runs and positions count Unicode code points, not UTF-16 units; an inline image counts as one.
7. Headings come from three places: a "headings" navigation container (levels 1 to 6), a style layout hint plus a heading-level number on the node, or the table of contents depth. The first two are reliable; the rest is a guess.
8. The table of contents, landmarks, print page list and headings are navigation containers inside `$389`. Each entry targets a position (a node id plus an offset), which a reader maps to a place in its own flattened text.
9. Fixed layout, print replica, comics, magazines, children's books, and Scribe notebooks are marked in the metadata or the sections. A text reader recognizes and refuses them.
10. Every fact on the container, symbol table, walk, headings and navigation was exercised on one real container with a small read-only script; all 185 Ion entities decoded and every navigation target resolved.
11. No Amazon-made KFX is available to verify against. The only sample is from a third-party converter.
12. Size of the job: about 2,000 to 2,400 lines of Swift for DRM-free `.kfx` and `.kfx-zip`, against FMT52's 1,700 to 2,300; the `.kpf` form adds 450 to 600 and is not recommended first.
13. Recommendation: build the recognizer and refusal first, then the Ion reader and container, then the walk, then navigation. Get one real Amazon-made file before declaring it done.

## 1. The plugin

- **What it is.** "KFX Input", a calibre input-format plugin by John Howell (2016 to 2026). It reads Amazon KFX and converts it to EPUB. Version 2.34.2, from calibre's plugin index. Every source file carries "GPL v3". The zip also holds a second front end (a "From KFX" action, a metadata reader, and two import helpers) and a command-line entry point.
- **What it reads.** File types `.kfx`, `.azw8`, `.kfx-zip`, `.kpf`. It also takes `.azw`, `.azw9`, `.md`, `.res`, `.yj` and a few more as container files found beside a book. It can write: a single merged KFX container from a `.kfx-zip` (its "package" helper), an EPUB, a CBZ or PDF for image books, and an unpacked text dump.
- **What it will not do.** It will not read protected books. A container that starts with the DRMION signature raises a DRM error, and calibre shows "This book has DRM". (An optional third-party DRM-removal plugin can be present in calibre; the plugin calls it only for one narrow case, see part 3. TextMouth does not do this.)
- **Other limits** it states itself: fixed layout, magazines and PDF content do not convert well to EPUB; it warns about them.
- **Bundled symbol catalogue.** It holds the numbered shared table only (see part 5).
- **The same author's other plugin**, "KFX Output", makes KFX from EPUB by running Amazon's Kindle Previewer, which produces KPF, and repackaging the result as an unencrypted single KFX file [W]. Its MobileRead page says Amazon-bought KFX uses an encrypted main container and a DRM voucher, and that the plugin's output is unencrypted [W].

## 2. The packagings

| Packaging | What it holds | How to tell from the bytes | Likely for a TextMouth user? |
|---|---|---|---|
| `.kfx` (single) | One container. It may hold everything (metadata, text, resources) or only the main part | First 4 bytes `43 4F 4E 54` ("CONT"), then `02 00` (version 2) or `01 00` (version 1) [V for v2] | Yes if DRM-free: Kindle Previewer plus the KFX Output plugin, kfxgen, and possibly personal documents pulled from an e-ink Kindle [?] |
| `.kfx` with a `.sdr` folder beside it | The book, plus a sidecar folder with more containers (metadata, resources) and, for protected books, a voucher file | Same names: `Book.kfx` and `Book.sdr/`; look for other `.kfx` files and a file called `voucher` anywhere under the folder | On a Kindle's documents folder. The main file alone may lack resources |
| `.azw8` | A KFX container, used by Kindle for iOS and Mac. Same CONT layout | CONT or DRMION bytes, as for `.kfx` | Unlikely |
| `.azw`, `.md`, `.res`, `.voucher` in a folder named like `B0xxxxxxxx_EBOK` (ten characters starting with B, then `_EBOK` or `_EBSP`) | Kindle for PC and the old Mac app. The `.azw` is the book container, `.md` metadata, `.res` resources, `.voucher` the key envelope | Folder name pattern; the container files have the same CONT or DRMION bytes. The plugin author marks the iOS and Mac variants "untested" [P] | Only for downloaded purchases, which are protected |
| Kindle for Android and Fire | A folder named like `B0xxxxxxxx` (optionally `_sample`) with a main `.kfx` and `.ast` files | Folder name pattern | Protected purchases [P] |
| `.kfx-zip` | A plain ZIP made by gathering the files above: main container, other containers, resource files, voucher. Flat names. It is calibre's own bundle format, not an Amazon one | First 4 bytes `50 4B 03 04` (ZIP), members with CONT or DRMION starts | Only if someone made one with calibre |
| `.kpf` | Kindle Create's and Kindle Previewer's package: a ZIP holding a `.kdf` file (an SQLite database), a `.kcb` JSON file, and a `resources` folder | ZIP signature; a member ending `.kdf` | Authors only; see below |
| `.kdf` | The SQLite database inside a `.kpf`, also found loose | Starts with the 16 bytes `SQLite format 3` and a zero. **A twist**: a `.kdf` may have fingerprint blocks spliced into it (see below), which must be cut out before SQLite will open it | Rare |
| `.ion` / ZIP with `book.ion` | The plugin's own text dump of a book | Not an Amazon format | No |

**Not KFX.** A file whose bytes 0x3C to 0x43 read `BOOKMOBI` or `RBINCONT` is MOBI or KF8 (`.azw`, `.azw3`), a different reader. A PalmDB with creator `CONT` at offset 0x40 is the old Mobipocket-era container, also not KFX [P].

**Container roles** inside a book. A container is classified by which fragment types it holds: any of `$259`, `$260`, `$538` makes it the **main** container; otherwise any of `$258`, `$419`, `$490`, `$585` (or a symbol table of its own) makes it a **metadata** container; otherwise `$417` (raw media) makes it an **attachable** container [P]. A single-file book written by a converter, like the sample, puts everything in one container [V].

**The `.kdf` fingerprint wrapper [P].** Some `.kdf` files have extra 1,024-byte records inserted: the first at file offset 1,024, and then one every 1,048,576 bytes after that (1,024 times 1,024). Each record starts with the four bytes `FA 50 0A 5F`. Remove each record and the result is a valid SQLite file. If the four bytes are not at offset 1,024, nothing was inserted.

**KPF contents [P].** The database has tables for fragments (an id string, a payload type, and the payload), fragment properties, an id translation (an integer id to a string id), capabilities, plus extra tables in special books (dictionary indexes, notebook actions). Fragment payloads are Ion binary, annotated as in a KFX container, but the ids are strings and the books are "pre-publication": text may sit in the nodes as plain strings instead of in content fragments, and children may be given as names of inline fragments (`$608`). A KPF reader needs its own fix-up pass. The plugin's fix-up runs to 200 lines or more. KPF is not a first target.

## 3. Protection

How a protected KFX shows itself, in order of how early a reader can tell:

1. **The first eight bytes of a container file are `EA 44 52 4D 49 4F 4E EE`** (the bytes of "DRMION" with a 0xEA byte before and a 0xEE byte after) instead of `CONT`. That is the signature for an encrypted Ion envelope. The plugin also expects a matching eight-byte trailer when it strips the envelope (it removes eight bytes at each end), so the envelope is signature, payload, trailer. **[P]**
2. **A voucher file**: a file called `voucher` anywhere under the `.sdr` folder, or a file with the extension `.voucher` in the Kindle-for-PC/iOS/Mac folders. The plugin's gathering step includes these because the key material is needed to decrypt. **[P]**
3. **Inside a ZIP (`.kfx-zip`)**: any member starting with the DRMION bytes, or any member named `voucher` or ending `.voucher`.
4. **Inside a `.kpf`/`.kdf`**: any fragment payload (a blob) that starts with the DRMION bytes. The plugin checks every payload this way and refuses the book.
5. **Per-container fields** `$410` (compression type) and `$411` (DRM scheme), in both the container info and each entity header, are 0 in every file the plugin accepts. A nonzero value is only logged by the plugin, not handled. A reader should refuse a nonzero value in either field, because it cannot know what it means.

What a reader can still get from a protected book: the **metadata container** is often readable (title, author, ASIN), because the plugin has a mode that skips protected containers and still reads metadata from the others. That lets the app say "this is a protected book, *Title* by *Author*" without reading its text. **[P]**

One more case, so it is not mistaken for protection: some small files, notably `metadata.kfx`, start with the DRMION bytes but are a compressed, not encrypted, wrapper. The plugin tries to unwrap these only if a separate DRM-removal plugin is installed in calibre. TextMouth treats every DRMION start as a refusal; a refusal is the safe answer. **[P]**

**Refusal rule for a reader, from the bytes alone, before anything else:** read the first 8 bytes. If they are the DRMION signature, refuse as protected. If they are `CONT`, go on. For a ZIP, apply rule 3. For an SQLite start, rule 4 (after cutting out any fingerprints). For a `.sdr` folder or sibling file set, rule 2. Do the check on every container file in a set, not only the main one.

## 4. The container

All integers are little-endian. Offsets in the table are from the start of the file unless said otherwise. **[V]** for version 2 on the sample; version 1 is **[P]** only.

### 4.1 File header (18 bytes)

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 4 | signature | `CONT` (`43 4F 4E 54`) |
| 4 | 2 | version | 2 in the sample. 1 and 2 are known; the plugin logs an error for anything else but continues |
| 6 | 4 | header length | Bytes from file start to the first entity byte. 8,453 in the sample. The minimum is 18. Entity offsets are relative to this point |
| 10 | 4 | container info offset | In the sample 8,138 |
| 14 | 4 | container info length | In the sample 80 |

Anything shorter than 18 bytes is not a container. After the container info struct and before the first entity (the rest of the header) there is an ASCII text of the form `[{key:"kfxgen_package_version",value:"..."}, ...]`, keys unquoted. Known keys: package version, application version, `kfxgen_payload_sha1` (the SHA-1 of all bytes from the header length to the end of file, in hex; **[V]** it matched), and `kfxgen_acr` (the container id). A reader can ignore all of it, or use the SHA-1 to detect a truncated file.

### 4.2 Container info (an Ion struct, with a version marker, at the offset above)

| Field | Meaning | Sample value |
|---|---|---|
| `$409` | container id (string) | `CR!VBVIAMAKUZXCNNZ8NYN7SM17K9HU` |
| `$410` | compression type; must be 0 | 0 |
| `$411` | DRM scheme; must be 0 | 0 |
| `$412` | chunk size; 4,096 is the norm and nothing else was seen | 4096 |
| `$413`, `$414` | offset and length of the **entity table** | 18, 5,328 (= 222 rows) |
| `$415`, `$416` | offset and length of the **document symbol table** | 5,346, 2,756 |
| `$594`, `$595` | offset and length of the **format capabilities** struct (version 2 only) | 8,102, 36 |

In the sample the layout from the front is: header (18), entity table, document symbol table, format capabilities, container info, the JSON-like text, then the entities. Do not rely on that order; use the offsets. If a length is 0 the item is absent.

### 4.3 Entity table

Rows of 24 bytes, back to back, filling `$414` bytes:

| Offset in row | Size | Field |
|---|---|---|
| 0 | 4 | entity id, a symbol number (`348`, symbol `$348`, means "no name": a singleton fragment) |
| 4 | 4 | entity type, a symbol number (the fragment type, such as 260 for `$260`) |
| 8 | 8 | offset of the entity, **from the end of the header** (header length + this) |
| 16 | 8 | length of the entity |

**[V]** The sample's entities are laid end to end with no gaps, and the last one ends exactly at the end of the file. A reader should check that each entity ends inside the file and refuse the file otherwise.

### 4.4 Entity header and payload

| Offset in entity | Size | Field |
|---|---|---|
| 0 | 4 | `ENTY` (`45 4E 54 59`) |
| 4 | 2 | entity version; 1 is the only known |
| 6 | 4 | entity header length (21 in the sample); the minimum is 10 |
| 10 | header length - 10 | an Ion document (with its own version marker) holding a struct with `$410` and `$411`, both 0 |
| after the header | the rest | the payload |

The payload is a complete Ion document (version marker, then one value) for every type except two: **`$417` (raw media) and `$418` (raw font) are the bytes of the file itself**, not Ion. **[V]** A `$417` payload in the sample begins `FF D8 FF E0`, a JPEG.

If the Ion value is wrapped in an annotation equal to the entity's own type, and the entity id is `$348`, the annotation is just the type repeated; unwrap it. **[P]** The sample does not annotate.

### 4.5 What can be compressed or protected

In the files the plugin handles: nothing. The compression-type field exists on the container and on every entity but is always 0. No compressed KFX has been seen by this author. A DRMION envelope can contain compressed data (see part 3), but that is a protection refusal here.

### 4.6 Version differences

- **Version 1** (container version 1): has no format capabilities struct and no `$594`/`$595`. Books of this version may have no document data fragment (`$538`) and no `$265`; the reading order is then in the metadata fragment `$258` (key `$169`). **[P]** No version 1 file was available.
- **Version 2**: as described.

## 5. Ion

The public specification is https://amazon-ion.github.io/ion-docs/ (Apache 2.0). Check the binary page against this list. The binary page was fetched and read for this study **[W]**.

**What a KFX reader needs from binary Ion:**

- The version marker `E0 01 00 EA` at the start of every Ion document. A document in the file may contain more than one value; the plugin accepts a marker again between values, which a reader should do too.
- The descriptor byte: high nibble is the type, low nibble is a length or flag. Length 14 means a VarUInt length follows. Length 15 means a typed null. Type 0 (null) with length under 14 is **padding** and must be skipped, including as a struct member.
- Types: 0 null/pad, 1 bool (the low nibble is the value), 2 positive int, 3 negative int, 4 float (0, 4, or 8 bytes), 5 decimal, 6 timestamp, 7 symbol, 8 string (UTF-8), 9 clob, 10 blob, 11 list, 12 s-expression, 13 struct, 14 annotation.
- A struct member is a VarUInt symbol id followed by a value. A struct whose descriptor low nibble is 1 is "sorted" and has a VarUInt length; the plugin treats it as variable length. Do the same.
- An annotation wraps exactly one value: a VarUInt length of the annotation list, the annotation symbol ids, then the value. Fragments seen in the wild have one or two annotations (id and type; the `$393` unit and `$391` container annotations in navigation).
- **Decimals** matter little to a text reader. They appear in style sizes (`{$307: value, $306: unit}`) and positions. They may be skipped as opaque unless emphasis size matters. **Floats and timestamps** are present in metadata and may be skipped as opaque.
- **Symbols**: the value is an unsigned integer; resolve it as in the next paragraphs.
- **VarUInt**: groups of 7 bits, most significant first; the last byte has its high bit set. **VarInt** is the same with a sign bit at 0x40 of the first byte.
- Integers up to 8 bytes only are seen. 64 bits are enough.

**Symbols.**

1. The **system table** is fixed by Ion: ids 1 to 9 are `$ion`, `$ion_1_0`, `$ion_symbol_table`, `name`, `version`, `imports`, `symbols`, `max_id`, `$ion_shared_symbol_table`. In KFX, `name` (4) is the field used in the content fragment and the style-name fields of some fragments, and `max_id` (8) appears in the document data.
2. The **shared table** is `YJ_symbols`. Ids start at 10. Symbol number *n* means the field or value written `$n` everywhere in these notes. **A reader does not need any name for a shared symbol, only the number.** The plugin's bundled catalogue is exactly the numbers `$10` to `$859` and marks 284 of them with a question mark as "not expected in books". It holds no human names, which is why this document uses numbers.
3. The **document symbol table** (from `$415` and `$416`) is an Ion value annotated `$ion_symbol_table`, a struct with `imports` (a list of structs with `name`, `version`, `max_id`) and `symbols` (a list of strings). In the sample: one import of `YJ_symbols`, version 10, `max_id` 851, plus 255 local strings such as `c0`, `story_c1`, `content_1`, `s3`. **[V]**
4. **Unusual and important:** Ion says an import's `max_id` is the count of symbols taken from that table. KFX files count the nine system symbols as well. So with `max_id` 851 the shared symbols are ids 10 to 851, and **the first local symbol has id 852** (`max_id` + 1). **[V]**: in the sample, 852 is `s0` and 853 is `c0`, and the entity table's first section id is 853, `c0`.
5. Symbol 0 and ids that fall outside the table are unknown: handle them without crashing (the plugin shows them as `$id`).
6. **Do you need names at all?** For one container: only for **local** symbols, and only if you use them as keys. Within one container, local ids are enough as keys. For a book of more than one container, names are needed, because each container has its own table, and fragments in one refer to fragments in another by name. So read the symbol table's string list and key everything by name, and by number for the shared ones.

## 6. The fragments

A *fragment* is an entity: a type (a symbol), an optional id (a local symbol; `$348` means "none, only one of these"), and a value. Below, "field" means a struct member. All **[V]** on the sample unless marked.

### 6.1 Singletons and book-wide fragments

| Type | Name | What it holds |
|---|---|---|
| `$538` | document data | `$169` reading orders: a list of structs with `$178` (the order's name; `$351` is the default one) and `$170` (a list of section names, in reading order). Also writing direction and default font information, and `max_id` (a count that covers the book's own symbols). Absent in container version 1 |
| `$258` | metadata (flat) | In older books: keys like `$153` title, `$222` author, `$232` publisher, `$154` description, `$10` language, `$224` ASIN, `$424` cover, and `$169` reading orders. **[P]** In the sample it holds only the reading orders |
| `$490` | book metadata | `$491`: a list of categories. A category is a struct with `$495` (name: `kindle_title_metadata`, `kindle_ebook_metadata`, `kindle_capability_metadata`, `kindle_audit_metadata`) and `$258`: a list of `{$492: key, $307: value}`. Useful keys in `kindle_title_metadata`: `title`, `author` (may repeat), `language`, `publisher`, `description` (may contain HTML), `issue_date`, `cover_image` (a resource name), `ASIN`, `asset_id`, `book_id`, `cde_content_type`, `is_sample` **[V]** |
| `$585` | content features | `$590`: a list of feature structs (`$586` namespace, `$492` name, `$589` version). Read only for refusal (below) |
| `$593` | format capabilities | Version 2 only. Same sort of list. Ignore |
| `$419` | container entity map | `$252`: a list of `{$155: container id, $181: names of fragments in it}` |
| `$264`, `$265`, `$550` | position and location maps | Map internal position ids to character counts for Kindle's own page counter ("locations"). **Not needed for reading text** |
| `$395` | resource path | Empty in the sample. Ignore |

### 6.2 Sections and storylines (the book's structure)

- **Section** `$260` (id: a local symbol such as `c0`). Fields: `$174` its own name, `$141` a list of **page templates**. A page template is a struct with `$155` (its position id), `$159` (a type), `$156` (layout) and `$176` (the name of a storyline). In a reflowable book each section has one storyline. Several templates in one section happen with special layouts only. Fixed-layout and magazine templates carry `$171` (a condition). **[V]**
- **Storyline** `$259` (id like `story_c1`). Fields: `$176` its own name, `$146` a list of **nodes**. **[V]**
- **Node**: a struct, in a tree. Fields in use:

| Field | Meaning |
|---|---|
| `$155` | the node's position id (an integer). The same numbering is used by navigation and anchors |
| `$159` | node type (below) |
| `$157` | name of a style fragment |
| `$145` | the text. **Either** a string, **or** a struct `{name: <content fragment name>, $403: <index>}` pointing at string number *index* in that content fragment's list. **[V]** (1,050 of 1,274 nodes in the sample; none inline) |
| `$146` | children: a list of nodes. In unfinished KPF books the list may also hold plain strings or names of inline fragments (`$608`) **[P]** |
| `$142` | a list of **runs** (below) |
| `$176` | a node may name another storyline to expand in place **[P]** |
| `$175` | resource name (image) and `$584` alt text |
| `$156` | layout of a container |
| `$601` | render mode. `$283` means inline (the node flows within the text line) **[P]** |
| `$615` | classification: `$618` footnote, `$619` endnote, `$281` footnote (older), `$688` and `$689` math, `$453` table caption **[P]** |
| `$790` | heading level, an integer (2 on every heading in the sample). **[V]** |
| `$100`, `$104`, `$102` | list style, start number, indent |
| `$683` | a list of annotations, `$687` being the kind: `$690` carries MathML text, `$584` an accessible name, `$749` alternate content **[P]** |
| `$69`, `$171`, `$591`, `$592` | "ignore", "condition", "exclude if", "include if". Their presence suggests layouts the reader should not flatten |

- **Node types** (`$159`): `$269` text block, `$270` container, `$271` image (resource name in `$175`, alt text in `$584`), `$272` vector graphic, `$274` embedded plug-in object, `$276` list, `$277` list item, `$278` table, `$151` table head, `$454` table body, `$455` table foot, `$279` table row, `$596` horizontal rule, `$439` content not displayed. A table cell is an ordinary container or text node inside a row. **[P]** for all but `$269`, `$270`, `$271`.
- **Content** `$145` (id like `content_1`): fields `name` (its own name, the system symbol 4) and `$146` (a list of strings). **[V]** Strings do not include paragraph marks; each string is a paragraph, a heading, or part of one. The sample has 18 content fragments for 17 storylines.
- **Run** (in `$142`): `{$143: start offset, $144: length, $157: style name, $179: link name, $616: ($617 means "note reference"), ...}`. The offset and length count Unicode **code points** within the node's text. **[P]** The plugin has a note about narrow Python builds counting UTF-16 pieces separately, which confirms the intent. Swift `String` counts grapheme clusters, so use the unicode scalar view. Drop-cap runs use `$125` and `$126`; ruby text uses `$757` to `$759`. Runs may overlap or nest. **[?]**
- **Style** `$157`: `$173` its name, then properties. Needed for reading: `$13` font weight (`$361` bold; `$350` normal; `$355` to `$363` hundreds), `$12` font style (`$382` italic, `$381` oblique, `$350` normal), `$23` decoration (`$328` underline), `$583` variant (`$369` small caps), `$44` baseline shift (raised or lowered, for notes), and `$761` **layout hints**, a list that holds `$760` for "heading" and `$282` for "figure", `$453` for "caption". A style's properties are filled into a node only for keys that the node does not itself set. **[V]** for the shapes; `$361` and `$382` are the plugin's mapping.
- **Anchor** `$266`: `$180` its own name, then **either** `$183` (a position `{$155: node id, $143: offset}`; the offset is absent when 0) **or** `$186` (an external URI string). **[V]**
- **External resource** `$164` and **raw media** `$417`: `$175` name, `$165` the name of the raw entity (a local symbol such as `resource/e0`), `$161` format, `$162` MIME type, `$422` and `$423` pixel sizes. Not needed for text. **[V]**

## 7. The walk, in plain words

1. Check the signature and refuse protection (part 3). Read the header, container info, document symbol table, entity table.
2. Make a symbol list: ids 1 to 9 system, 10 to `max_id` shared (numbers only), then the local strings.
3. For each entity: read the header; for `$417` and `$418` keep the bytes unread; for everything else decode the Ion value. Index by (type, id). Singletons are `$348`.
4. Decide whether this is a book to read: part 10's list. Refuse otherwise.
5. Get the reading order: `$538` → `$169`, else `$258` → `$169`. Take the reading order named `$351` (default) or the first. Concatenate section names; skip repeats.
6. For each section, in order, find its `$141` page templates and the storyline name in each `$176`. Open the storyline `$259`.
7. Walk the storyline's `$146` nodes depth first, in list order. At each node:
   - if the node has a position id `$155`, note where the next text starts (this is how navigation will find it);
   - if it has `$145`, the text is that string, or string number `$403` of content fragment `name`. Emit a paragraph (a text block `$269` is one paragraph; the string already has no paragraph mark);
   - a container `$270`, list `$276`, list item `$277`, table `$278` and its parts only carry children; recurse into `$146`. Emit a paragraph break between blocks. A list item `$277` may hold its own text or children; a text block can be a direct child of a row `$279` or of a container within one (a cell);
   - an image `$271` is one position, with alt text in `$584`; the app chooses whether to speak the alt text. A rule `$596` is one position and no text;
   - an inline-render node (`$601` = `$283`) is part of the line it sits in; the code points count of its position is 1 for non-text content;
   - a node of footnote or endnote class (`$615`) has its text in the flow here. The reference in the body is a run with `$616` = `$617` and a link `$179`. A reader should let the user decide: skip the note bodies in the main flow, or read them where they stand. Do not drop them silently;
   - a node with `$176` expands that storyline in place.
8. **Emphasis.** For a text block, the runs (`$142`) give code-point ranges with a style name. Look the style up, read `$13`, `$12`, `$23`, `$583`; link runs carry `$179`.
9. **Links.** A run with `$179` names an anchor; the anchor (`$266`) gives a position or a URL. A position inside the book becomes a jump; an external URL is shown only if the app has that notion.
10. **Verified on the sample** with a small script: 17 sections, 1,088 text units and 141,787 characters came out in order; 13 headings, 13 contents entries, 2 landmarks and 77 page-list entries all resolved to a node; 12 internal anchors resolved.

**Position to place.** A position is `(node id, offset)` where the node id is a `$155` value. The id can name a text block (offset counts code points in its text), but also a container or a section's page template, whose "place" is the start of its first text (the contents entries of the sample point at containers like this). So, while walking, record for every `$155` the text position at which that node begins (the start of its first descendant text), plus the node's own text start. A position `(id, k)` is the id's start plus *k* code points for a text block, and just the id's start for anything else. **[V]**: all navigation targets of the sample resolved with this rule.

## 8. Headings

What the book marks, strongest first:

1. **A headings navigation container** (`$235` = `$798` inside `$389`), named `headings` in the sample. Each unit may carry `$238` = `$799`, `$800`, `$801`, `$802`, `$803`, `$804`, meaning heading level 1 to 6; the unit's `$246` position is the heading's node. Units nested under a typed unit (in `$247`) have no type of their own and take their parent's level. In the sample all 13 units resolved to the 13 chapter heading nodes, level 2. **[V]** for shape; the inheriting rule is **[P]**.
2. **The node itself.** A node whose style has `$761` containing `$760` ("heading") and that has no block children is a heading; its level is the node's `$790` (an integer). If a node has none, use the most recent level seen in the file, starting at 1. In the sample all 12 `$790`s were 2 and the style had the hint. **[V]** A converter-written file used `$790` with a different meaning (as "first entry of a section"; kfxgen's notes say so [W]). So trust `$790` only together with the `$760` hint or a headings unit.
3. **The table of contents depth**, when there is no headings container: the plugin treats a top-level contents entry as level 1 and each nesting as one deeper, to 6. This is a guess about meaning, not a mark in the book.
4. **Anything else** (bold large text alone) is style guessing, and the plugin does not do it either.

A reader can trust 1 and 2. Fall back to 3 for navigation only. Do not guess headings from font size.

## 9. Navigation and pages

- `$389` is **book navigation**: a list (in the sample, one struct) of `{$178: reading order name, $392: a list of navigation containers}`.
- A **navigation container** (`$391`; annotation) has `$235` its type, `$239` its name, `$247` its units. Types: `$212` table of contents, `$236` landmarks, `$237` print page list, `$798` headings, `$213` and `$214` (magazine-style tables, with `$248` entry sets by orientation). A container can also import others by name. **[P]**
- A **navigation unit** (`$393`; usually inline as an annotated struct, but possibly a separate fragment named in `$247` **[P]**) has `$241` a representation (`$244` the label, `$245` an icon, `$146` a description), `$246` the target position `{$155, $143}`, `$238` a type for landmarks and headings, `$247` children (nested).
- **Table of contents**: nested units; the label is `$241/$244`; the target is `$246`. **[V]** (13 entries).
- **Landmarks** (`$236`): type `$233` cover, `$396` start of body text, `$269` text, `$212` the contents page. **[V]** shape (`$233` cover). A reader can use `$396` for "start reading".
- **Print page list** (`$237`): each unit's label is the printed page name (`1`, `xii`...) and `$246` its position; **[V]** 77 entries in the sample. **A page list named `APPROXIMATE_PAGE_LIST` is machine-made** (written by the KFX Output tooling) and is not print pages; the plugin discards it. **[P]**
- **Section navigation** `$390` (list of `{$174: section, $392: containers}`) is for magazines only.
- **Anchor to place**: see part 7. A target is not a text offset into the whole book; it is a node plus a code-point offset inside it. A reader's page and heading features need a table from node id to its place in the flattened text.

## 10. Leave out, and when to refuse

What the plugin does that TextMouth does not need: building the EPUB package, CSS conversion (the property table is the biggest piece of the plugin), image and font decoding (including a JPEG-XR decoder), PDF and CBZ output, dictionary processing, Scribe notebook and handwriting conversion, magazine and comic panel logic, KVG vector graphics, MathML restoration, ruby conversion, and the position/location maps.

**How a reader recognizes a book it should refuse, because it has no reflowable text:** (all **[P]**)

| Mark | Meaning |
|---|---|
| metadata `kindle_capability_metadata/yj_fixed_layout` = 1 | fixed layout |
| same, = 2 | print replica (page images/PDF with a text layer) |
| same, = 3 | PDF-backed fixed layout |
| `yj_textbook` | print replica (textbook) |
| `yj_publisher_panels`, `yj_facing_page`, `yj_double_page_spread`, `continuous_popup_progression` (0 comic, 1 children), `yj_has_text_popups` | comics and children's books |
| `cde_content_type` = `MAGZ`, or `periodicals_generation_V2` | magazine / periodical |
| `$538` has `$665` | comic panel mode |
| a section with a field starting `nmdl.` (e.g. `nmdl.canvas_width`), or a `.kdf` with action or delta tables | Scribe notebook |
| `is_dictionary` / `dictionary_lookup` | dictionary: leave out in a first version |
| page templates whose layout `$156` is `$324`, `$325`, `$326`, `$437` | fixed, magazine, scale-fit, spread |
| there are sections but no node with text | image-only |
| `cde_content_type` = `EBSP`, or `is_sample` true | a sample, a short book; it is readable and may be read; mention it |

Also refuse when the reading order is missing, when a referenced section or storyline is missing, when the Ion is damaged, or when an entity runs past the end of the file.

## 11. The size of the job

FMT52's estimate: 1,700 to 2,300 lines (Ion reader about 400, container 300, storylines 800 to 1,200, navigation 150).

| Part | Swift lines (with the comments the project requires) |
|---|---|
| Recognizer and refusals (bytes, ZIP scan, voucher names, mark list) | 150 to 200 |
| Ion binary reader (types, VarUInt, struct, annotation, pads, skipping decimals, timestamps) | 300 to 400 |
| Symbols (system, shared numbers, local names, max_id rule) | 80 to 120 |
| Container and entities (header, table, bounds, hashes) | 200 to 250 |
| Fragment index and typed accessors | 100 to 150 |
| Metadata and reading order | 100 to 150 |
| Walk (sections, storylines, node types, lists, tables, images, notes) | 600 to 800 |
| Styles (bold, italic, underline, heading hints) | 80 to 120 |
| Navigation and positions (TOC, headings, landmarks, page list, node-to-text map) | 220 to 300 |
| Multi-file sets (`.sdr` sibling files, `.kfx-zip`, Kindle folder forms) | 120 to 200 |
| Total, DRM-free `.kfx` and `.kfx-zip` | about 1,950 to 2,700 |
| `.kpf` (ZIP, SQLite, fingerprint cut, string ids, inline text, id translation) | add 450 to 600 |

The FMT52 estimate fits the low end. Tests roughly double the figure.

**Riskiest parts**, in order:

1. The walk: without real Amazon files, the variety (nested containers, inline fragments, lists, tables, footnote classes, conditional templates) is guessed. A third-party converter's output is simpler than Amazon's.
2. Multi-container books: the main container, its metadata container and the resources can be separate files with their own symbol tables.
3. Counting in code points, and what each non-text node counts as, for runs and positions.
4. Heading levels from three sources that sometimes disagree.
5. KPF, if built: fingerprint cuts, SQLite, id translation.

## 12. Samples

No Amazon-made KFX is public. Options:

- **Kindle Previewer 3 plus calibre's KFX Output plugin.** The plugin converts EPUB to KPF using Previewer, then repackages the KPF as an unencrypted single KFX. **[W]** MobileRead's plugin page names Previewer (3.107 recommended; 3.38.0 is the lowest that works; 4.x is supported but not recommended) for Windows or macOS, or Wine on Linux; calibre 6.0 or later. The page does not say an Amazon account is needed **[W]**, and the author could not confirm whether Amazon's Previewer download needs one **[?]**. This gives a real Amazon-pipeline file: the best test source. Its cost is two installs by the user.
- **kfxgen** (`github.com/jloutsch/kfxgen`). **Real**: created 2026-06-27, releases as late as v5.23.0 (2026-11-03), 27 stars at the time. **Licence GPL 3**, and its NOTICE says it contains a modified subset of the same plugin's library. It is a calibre output plugin that writes KFX from EPUB in Python without Previewer, tested on devices and checked against a 90-book Project Gutenberg set by its author, who credits help from Claude. Its docs say the symbol meanings were recovered by diffing against Amazon and calibre-made files. A reader tested only on kfxgen output is partly tested against the same understanding that wrote the file, so it would be a fair check of the reader's reading of a plausible file, not of Amazon's. Its files are data, so the licence of the program does not reach them, but the book text is the user's own EPUB. It needs calibre to run; the author did not run it.
- **ebook-rs's Alice KFX** (`SV-stark/ebook-rs`, MIT licence, `samples/Alice in Wonderland - Lewis Carroll.kfx`, 1,134,261 bytes, added in a commit of 2026-08-08). Its tail text says `kfxgen_package_version "boko-0.5.0"` and application `boko`, so it was written by boko **[V]**. It is a real, well-formed version 2 container with 185 decodable Ion entities, a headings container, 13 contents entries, 77 page-list entries, 12 anchors, 38 images. It was downloaded into `build/orchestrator/followups1105/kfx-plugin/samples/alice-ebook-rs.kfx` and every layout in part 4 to 9 was checked against it. The book text (Carroll's) is in the public domain; the file's own terms are unstated, so do not add it to the repository.
- **Others.** Send to Kindle documents on a recent Kindle: since October 2023 Amazon converts most personal documents sent this way to KFX **[W]**; whether the copy on the device is unprotected is **[?]**. The user's own Kindle may hold such files in its documents folder. Previewer can also open a KFX through the KFX Input plugin. **[W]**

**What a hand-built test can cover:** the Ion reader (every type, pads, long lengths, sorted structs), the container (bounds, truncation, bad signatures), the symbol rules (the `max_id` offset), the DRM refusals (bytes, ZIP member names, voucher names), the walk on small invented storylines, headings by each of the three routes, code-point offsets with emoji and combining marks, and positions to text. A test writer for Ion is about 150 lines and is worth building. **What only a real Amazon file can cover:** the variety of nodes Amazon's pipeline really emits, real multi-container sets, real symbol tables with all the quirks, footnote and table markup, version 1 containers, and whether "refuse" triggers on exactly the books that Amazon marks.

## 13. Calibre as a yardstick (described, not done)

With a KFX sample, calibre plus this plugin can convert it to EPUB. That gives a reference to compare a TextMouth reader's text against, and a way for the user to read such a book now. With a throwaway configuration folder:

1. Make an empty folder, say `/tmp/calibre-kfx-config`.
2. Set `CALIBRE_CONFIG_DIRECTORY` to it (calibre's documented variable) for the commands below; also consider `CALIBRE_CACHE_DIRECTORY`.
3. Install the plugin zip into that configuration only, with `calibre-customize -a KFX-Input-2.34.2.zip`.
4. Convert with `ebook-convert Book.kfx Book.epub`. For a `.sdr` set or a Kindle folder, first gather the files into a `.kfx-zip` (the plugin does this on import) or convert from the folder. For a book with DRM, calibre stops with "This book has DRM". The plugin also has its own command: `calibre-debug -r "KFX Input" -- Book.kfx Book.epub`. **[P]**
5. Delete the folder afterwards. The user's real calibre configuration is not touched.

Unzip nothing from the plugin into TextMouth. The EPUB it produces is the reference to compare against (text order, headings, TOC).

## Facts not verified

- Anything about real Amazon files (no file available), including whether the e-ink `Title.kfx` for a Send-to-Kindle document is unprotected.
- Container version 1.
- The folder forms for Kindle for iOS, Mac and Android (the plugin's author calls the iOS and Mac ones untested).
- Whether Kindle Previewer needs an Amazon account.
- Whether a nonzero compression or DRM scheme field exists in any real file.
- The trailer of the DRMION envelope (inferred from the plugin removing eight bytes at each end).
- Overlapping and nested runs, ruby, drop caps, tables in real books.

## Added November 6, 2026: a file from Amazon's own tools

Kindle Previewer 4.0.4 is a free download from Amazon's KDP help page, and it needs no Amazon account. Its installer unpacks with `pkgutil --expand-full`, and its `Contents/MacOS/KindlePreviewer4CLI` runs from there: `KindlePreviewer4CLI book.epub --convert --output folder --locale en` writes `folder/KPF/book_epub.kpf`. calibre's KFX Output 2.22.0, under calibre 9.18 (both plugins need calibre 6.0 or later), takes the KPF and writes a single `.kfx`.

**[V]** on that file, made from the public-domain `TestData/alice.epub`: the walk in these notes gives the source EPUB's 30,585 words in the same order, in 902 text units and 19 sections. The reading order is named `$351`. `$538` is there, and so are the navigation containers `$236`, `$212`, and `$798`, the last with heading levels. A heading with a line break holds a newline in its text. The `.kdf` in the KPF has the fingerprint block the notes describe: `FA 50 0A 5F` at offset 1,024, in a file one 1,024-byte record longer than its 128 pages of 4,096 bytes. The KFX's contents come from Amazon's conversion, but its `CONT` container comes from the plugin, so a store-bought file's container is still unverified.

## Added November 6, 2026: what the reader's review found on Amazon's output

From real files made with Kindle Previewer, read with a small reader written from the Ion specification and these notes. No plugin code or output was read.

- **Part 6.2:** strings in `$146` are not only for unfinished KPF. Finished Amazon files use them for inline content, with runs and positions on the parent counting across pieces.
- **Part 7:** template positions are real (boko). Part 10 (`$326`) is confirmed on covers only.
- **Amazon cuts:** forced breaks make new sections, and paragraphs over about 64,000 characters become sibling `$269` children.
- **A page list vanishes whole** when a label is not a number or Roman numeral. A list holding `A-3` and `4b` gave no `$237`.
- **Weights and lists:** `$360` is 600, `$361` is CSS bold, `$362` is `b` and `strong`, `$363` is 900. `$340`, `$341`, `$342` are bullets by depth, and `$343` decimal, `$345` upper Roman, `$346` lower alpha.
- **`$683`** is confirmed on math. `$756`, `$757`, `$758` hold ruby. `$597` holds `IS_TARGET_SECTION`.
- **Position of an empty element** at a paragraph's end is the last code point, not the end.
- **Previewer:** inline SVG, video, and audio made no KPF in the small books, and a pre-paginated EPUB gives a `.mobi`.
