# textfmt-rvdtbook: every valid DTBook on its own imports, and a blank one is refused (review items 3, 13)

Slug `textfmt-rvdtbook`, branch `textfmt/rvdtbook` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## 1. A valid DTBook is refused (item 3, medium)

`DAISYParser.findDTBookXML(in:provider:)` (DAISYParser.swift, around 575-588, reached through `detectVersion` from `makeFileProvider` around 434) decodes only the first 500 bytes as UTF-8 and looks for "dtbook", and it skips any file named `metadata.xml`. So a DTBook in UTF-16, in Latin-1 or with CJK or Cyrillic head text, or with a long leading comment, is refused after `XMLDocumentSniffer` already said it is a DTBook. Make the sniffer's answer the one test: `XMLDocumentSniffer.rootKind(of:)` on the file's first `scanLength` bytes (read only that much where the provider allows; otherwise the bytes it read), the same sniff everywhere, never a second string search. Keep the `metadata.xml` and `.ncx` skips only if a test shows they are needed; a DTBook named metadata.xml is still a DTBook.

The reviewers' four variants are in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/review-textfmt-b/dtbooks/` (commented, latin1, russian, utf16) with their generator `make_dtbooks.py` beside them. Build the four in the test from code (adapt the generator's content into Swift), never reading the scratchpad from a test; each imports as `.daisy` with its title and its words.

## 2. A blank DTBook imports as an empty book (item 13)

`<dtbook><head/><book/></dtbook>` imports today as a book with no words, since `formatsRefusedWhenBlank` (FileImportService.swift, around 1287) leaves out DAISY. Refuse it, with "This file has no text to read.", only on the loose-DTBook path (a single .xml file read through `SingleFileProvider`): a DAISY package whose audio carries no text is a real book and must import as today. Find the narrowest place (the provider path in `DAISYParser`, or `readableContent` with the book's file being a loose .xml).

A 0-byte .xml, and one holding only white space, must be refused with the existing empty-file sentence ("This file has no text to read."), not with the not-DTBook sentence: in `unsupportedSourceError(for:)` (or wherever the .xml refusal is chosen), an empty or blank file is told it has no text.

## Tests (in `DTBookImportTests` and `XMLDocumentSnifferTests`)

Each fails before its fix: the four variants import; the blank DTBook is refused with the pinned whole sentence ("Could not import “blank.xml”. … This file has no text to read."); a 0-byte and a blank .xml likewise; and an existing DAISY package without text still imports (find one in the DAISY tests' fixtures, or run their tests).

Run `DTBookImportTests`, `XMLDocumentSnifferTests`, `DAISYPackageImportTests`, `DAISYMalformedXMLTests`, `DAISYPackageInventoryTests`, and `ZIPImportTests`.
