# textfmt-rvreader: one conversion per import, Cancel stops textutil, HTML or WordML named .doc, and tests of their own (review items 6, 8, 17)

Slug `textfmt-rvreader`, branch `textfmt/rvreader` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first, then `TextMouth/Parsers/TextutilDocumentReader.swift` and `TextMouth/Services/TextutilConverter.swift` whole.

## 1. One conversion per import (item 6)

Each import runs textutil twice: `ImportedFileMetadata.read` (FileImportService.swift, around 174) converts the source for its title and author, then the import's text extraction converts the staged copy. The first run's kill is swallowed (`try?`), so a hanging document costs twice the time limit. Convert once per import, and take the title and author from that one output:
- An import of a textutil format reads no metadata before staging (it is listed by its file name until then), and adopts the title and author the extraction's HTML head names before its record is written (`publishReadableBook` / `readableContent` / `writeVerifiedRecord`: find the narrowest place; the package keeps the name it was staged under, which is fine). Carry the head's title and author out of `MarkdownCacheService`'s extraction with the Markdown (`ExtractedCache` and `GeneratedCache` gain them, nil for every other format), never by a second conversion.
- `ImportedFileMetadata.read` still reads a textutil book's title and author for the launch refresh (`LibraryViewModel+MetadataRefresh`), off the main thread, as today.
- Tests: an import of `rtf/word-styles.rtf` and of `odt/handwritten.odt` runs textutil once (count runs: give `TextutilConverter` an injectable observer or count through a stand-in tool, in the style the file already uses for tools), and is titled "Word Styles Sample" by "A. Sample" and "Harbour Notes". A document that names no title is listed by its file name.

## 2. Cancel stops a running textutil (item 6)

`LibraryViewModel.cancelImports()` (LibraryViewModel+Import.swift, around 394) cancels queued imports, but a running textutil child keeps running: `TextutilConverter.html` waits through `AsyncBridge`, whose detached task is never cancelled. Make Cancel kill an import's running textutil child at once, and that import end as a cancelled import ends today (find how a cancelled ZIP batch or Ogg conversion reports it: `ImportCancelled`, `CancellationError`), leaving nothing behind. A regeneration outside an import (the reader, startup maintenance) is never stopped by the import's Cancel. Design it narrowly, for instance a registry of the import queue's running conversions that `cancelImports()` cancels, and if `AsyncBridge` needs a cancellable variant, add one beside `waitForResult` without changing its callers. Test with a stand-in tool that hangs: a cancel stops it within a second or two, the import throws the cancellation, and `WatchedProcess.runningChildCount` returns to what it was before.

## 3. An HTML or WordML file named .doc (item 8)

A .doc (or .dot, .rtf, .odt) whose content is HTML (Word's "Web Page" and many web exports) or WordML is refused as damaged, since textutil is told `-format doc`. Sniff it as RTF is sniffed (`TextutilSourceCheck`): WordML content (`XMLDocumentSniffer.rootKind` is `.wordML`) is read as `.wordml`; HTML content (after a byte-order mark and white space, `<!DOCTYPE html` or `<html`, case-insensitive, within the first 1,024 bytes; add `TextutilSourceCheck.beginsAsHTML`) goes to TextMouth's own HTML path (`TextFileDecoder` with `.html`, then `HTMLToMarkdownConverter.convert(_:stripDuplicateNavigation: true)`, and `HTMLParser.parse` for the direct reading), never to textutil, so no WebKit runs. The book keeps its format (`.doc`). Tests: headings-source.html copied as `page.doc`, and the WordML sample copied as `notes.doc`, each import with their headings.

## 4. Tests that collide with other builds (item 17)

- `TextutilImportTests.assertLeavesNoTextutilFiles` scans the shared temporary directory, where another build's textutil may be writing. Give `TextutilDocumentReader` an injectable root for its temporary working folders (a `@TaskLocal`, read on the caller's thread before any hop, as `DocumentByteLimit.current` is) and give each test its own sandbox root, which it then scans.
- `TextutilConverterTests` (around 198) requires exactly 0 running children: compare `WatchedProcess.runningChildCount` with the count taken before the test, as `WatchedProcessSafetyTests` does.

Another worker changes `TextutilHTMLStructure.swift` and adds one WordML call in `TextutilDocumentReader.markdown(from:html:)` at the same time: keep your changes out of that function. Run `TextutilImportTests`, `TextutilConverterTests`, `TextutilSourceCheckTests`, `IntegrationImportTests`, `ImportProgressTests`, `StagedImportTests`, `LogContentPolicyTests`, and `UncheckedConcurrencyPolicyTests`. Every new test fails without its fix.
