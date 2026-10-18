# textfmt-rvreaders: web archive Latin-1, SSML word boundaries, and SSML's type (review items 4, 14, 15)

Slug `textfmt-rvreaders`, branch `textfmt/rvreaders` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## 1. A web archive labelled ISO-8859-1 (item 4, medium)

`WebArchiveReader.mainPage(in:fileName:)` (WebArchiveReader.swift, around 85-89) decodes the bytes in the encoding the archive names. Labelled "ISO-8859-1", the bytes 0x93 0x94 0x97 0x85 0x80 come out as C1 control characters instead of “ ” — … €. `TextFileDecoder` already reads ISO-8859-1 and ASCII as Windows-1252, as browsers do (TextFileDecoder.swift, around 326 and 340): reuse that rule through one internal function there (move the existing mapping into it if it is inline), never a second mapping. Test: a page labelled "ISO-8859-1", and one labelled "us-ascii", holding those five bytes, read as “ ” — … €.

## 2. SSML words run together (item 14)

`<voice>Hello.</voice><voice>Hi.</voice>` gives "Hello.Hi.", and `Wait<audio src="h.mp3"/>then` gives "Waitthen" (SSMLReader.swift, around 132-176). A `voice` element's start and end, an `audio` element (empty or not), and the start of an `s` each separate words (a space, which the tidy step collapses). And `emphasis level="none"` writes no emphasis (its content only), the other levels and no level still `<em>`. Test each, with the words pinned.

## 3. SSML's type (item 15)

`supportedTypes` (FileImportService.swift, grep `org.w3.ssml`) appends the SSML type only when `UTType("org.w3.ssml")` is not nil, and `WebArchiveAndSSMLImportTests` (around 175-177) checks nothing when it is nil. The type is declared in `Info.plist`'s imported types: use `UTType(importedAs: "org.w3.ssml", conformingTo: .xml)`, which always returns the declared type, so the Open Book panel always offers .ssml; and make the test fail when the panel's types lack a type whose preferred extension is "ssml".

Run `WebArchiveReaderTests`, `SSMLReaderTests`, `WebArchiveAndSSMLImportTests`, `DocumentTypeDeclarationTests`, and the text decoder's tests. Every new test fails without its fix.
