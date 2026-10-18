# textfmt-sourcecheck: what a document's own bytes say before textutil reads it (FMT13, part 3)

Slug `textfmt-sourcecheck`, branch `textfmt/sourcecheck` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## Why

TextMouth will hand RTF, Word 97-2003 (.doc and .dot), and OpenDocument (.odt and .ott) files to textutil, always naming the format with `-format`, so textutil never guesses. Two things textutil cannot tell the listener, which a few bytes of the file can:

- **RTF under another name.** Many files named .doc are RTF (Word's "Save as RTF" keeps the name; many web exports do the same). textutil told `-format doc` refuses them, while `-format rtf` reads them perfectly (verified). So a file that begins as RTF is read as RTF whatever its extension.
- **A password.** textutil fails on a password-protected document exactly as on a damaged one. The research asks for a sentence that says which it is. In a Word 97-2003 file the File Information Block (FIB) at the start of the `WordDocument` stream says so: [MS-DOC] FibBase begins `wIdent` (2 bytes, 0xA5EC, so the bytes EC A5), `nFib` (2 bytes), `unused` (2), `lid` (2), `pnNext` (2), and then a 16-bit flags word at offset 0x0A whose bit 0 (0x0001) is `fDot` (a template) and bit 8 (0x0100) is `fEncrypted`. In an OpenDocument package, `META-INF/manifest.xml` holds a `manifest:encryption-data` element for each encrypted part.

This task writes the three checks as pure functions on files. Another task calls them.

## Read first (by line range)

- `TextMouth/Parsers/ArchiveEntryReader.swift` lines 112-124 (`Archive.openedForReading(at:)`) and 201-238 (`ArchiveEntryReader.read(_:in:limit:holdingToDeclaredSize:)`): every ZIP entry is read through it, with a limit.
- `TextMouth/Parsers/PackageSAXParser.swift` lines 40-60: how an `XMLParser` is set up (no external entities).

## What to build

A new file `TextMouth/Parsers/TextutilSourceCheck.swift`, `enum TextutilSourceCheck`:

1. `static func beginsAsRTF(_ url: URL) -> Bool`: reads at most the first 64 bytes; skips a UTF-8 byte-order mark and ASCII white space; true when the next bytes are `{\rtf`. False for a folder, a missing file, or anything else. Never reads the whole file.
2. `static func isEncryptedWordDocument(_ url: URL) -> Bool`:
   - False unless the file begins with the compound-file signature `D0 CF 11 E0 A1 B1 1A E1`.
   - Find the FIB without parsing the compound file: the `WordDocument` stream starts on a sector boundary, so look at each 512-byte-aligned offset from 512 on, within the first 8 MB, for the first one whose bytes are EC A5 followed by an `nFib` (little-endian) from 0x0065 to 0x0200 (Word 6 to Word 2007 and later write values in that range; 0x00C1 for Word 97 and after).
   - True when that FIB's flags word (little-endian, at its offset + 0x0A) has bit 0x0100 set. False when no FIB is found: textutil then tries, and fails with its own sentence if it must.
   - Read in chunks or with a `FileHandle`, never the whole of a large file at once. Expose the offset finder as `static func fibOffset(in data: Data) -> Int?` (or similar, on bytes) so tests can check it directly.
3. `static func isEncryptedOpenDocument(_ url: URL) -> Bool`: opens the ZIP with `Archive.openedForReading(at:)`; reads `META-INF/manifest.xml` through `ArchiveEntryReader.read` with a limit of 1,000,000 bytes; true when an `XMLParser` (namespaces processed, `shouldResolveExternalEntities = false`) meets an element whose local name is `encryption-data`. False when the file is no ZIP, the manifest is missing, too large, or unreadable.
4. `struct PasswordProtectedDocument: LocalizedError, Equatable`, the refusal another task throws: "This document is protected by a password. Save a copy without the password, then import that copy."

About 90 lines with comments. No other app file changes.

## Tests

A new file `TextMouthProductionTests/TextutilSourceCheckTests.swift`, class `TextutilSourceCheckTests` (run `xcodegen generate`). Every sample is a copy (`copyOfFormatSample`); modified copies are made in the sandbox.

1. `beginsAsRTF`: true for `rtf/headings.rtf`, for the same file copied as `notes.doc`, and for a copy with a UTF-8 BOM and a blank line put before it; false for `doc/headings.doc`, `odt/headings.odt`, an empty file, a missing file, a folder (`rtfd/headings.rtfd`), and plain text.
2. The FIB is found in each Word sample (`doc/*.doc`, `dot/*.dot`): `dot/headings-synthetic.dot` has `fDot` set (the research verified it) and `dot/libreoffice-tdf120761_zOrder.dot` has it clear (also verified), which shows the finder lands on the real FIB. None of the samples is encrypted.
3. A copy of `doc/headings.doc` with bit 0x0100 set in its FIB's flags is encrypted; the same copy with only `fDot` set is not.
4. `isEncryptedWordDocument` is false for an RTF, an empty file, a compound-file signature followed by zeros (no FIB), and a missing file.
5. A copy of `odt/handwritten.odt` whose `META-INF/manifest.xml` is replaced (open the copy with ZIPFoundation in `.update` mode, remove the entry, add one) by a manifest holding `<manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"><manifest:encryption-data manifest:checksum-type="SHA1/1K" manifest:checksum="AAAA"/></manifest:file-entry>` is encrypted; the samples (`odt/*.odt`, `ott/handwritten.ott`) are not; an RTF and a ZIP without a manifest are not.
6. The refusal's sentence is pinned word for word.

Run `TextutilSourceCheckTests`.

## Not yours

Do not call the checks from anywhere, and do not touch `BookFormat`, `FileImportService`, or the textutil runner.
