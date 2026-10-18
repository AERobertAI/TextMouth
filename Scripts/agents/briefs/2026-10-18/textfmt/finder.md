# textfmt-finder: the new formats open from the Finder, and an RTFD is one book in a folder or ZIP

Slug `textfmt-finder`, branch `textfmt/finder` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## Why

A book imports by Open Book…, by dragging it onto the Library, and by opening it from the Finder. The Finder offers TextMouth for a file only when the app's `Info.plist` declares the file's type among its document types. And an .rtfd is a package (a folder the Finder shows as one file), so a folder or ZIP of books that holds one must import it as one book, never as its TXT.rtf and a picture.

## Read first (by line range)

- `TextMouth/Resources/Info.plist` lines 36-120 (the first document types, their keys and tabs), 271-353 (the Word, PDF, DAISY, and TextMouth package entries; the last shows `LSTypeIsPackage`), and 374-460 (`UTImportedTypeDeclarations`).
- `TextMouth/Services/FileImportService.swift` lines 1440-1500 (`importCandidates(in:unpacking:)`).
- `TextMouth/Models/Book.swift`'s `BookFormat` (the cases `rtf`, `rtfd`, `doc`, `odt`, `wordml`, `webarchive`, and `ssml`, with their extensions).
- `TextMouthProductionTests/FormatSampleFixtures.swift`, for its `documentType(listing:)` helper (added with the Word templates).
- `TextMouthProductionTests/ZIPImportTests.swift`: grep `importCandidates` for how a test calls it.

## What to build

1. **Document types.** Add, after the PDF entry and before the DAISY ones, one entry per kind, each `CFBundleTypeRole` Viewer and `LSHandlerRank` Alternate (TextMouth never claims to be the default app for them), in the file's own tab layout:

   | `CFBundleTypeName` | `CFBundleTypeExtensions` | `LSItemContentTypes` |
   | --- | --- | --- |
   | Rich Text Document (RTF) | rtf | public.rtf |
   | Rich Text Document with Attachments (RTFD) | rtfd | com.apple.rtfd, and `LSTypeIsPackage` true |
   | Word 97-2003 Document (DOC) | doc, dot | com.microsoft.word.doc, com.microsoft.word.dot |
   | OpenDocument Text (ODT) | odt, ott | org.oasis-open.opendocument.text, org.oasis-open.opendocument.text-template |
   | XML Document (DTBook or Word 2003 XML) | xml | public.xml |
   | Web Archive | webarchive | com.apple.webarchive |
   | SSML Document | ssml | org.w3.ssml |

2. **SSML's type.** macOS declares no type for .ssml (it gives a dynamic one), so add an imported type declaration to `UTImportedTypeDeclarations`, after the Markdown one, as the others are written: identifier `org.w3.ssml` (SSML is a W3C recommendation), description "SSML Document", conforming to `public.xml`, with the extension `ssml` and the MIME type `application/ssml+xml` (RFC 4267).
3. **An RTFD in a folder or ZIP is one book.** In `importCandidates(in:unpacking:)`, a folder whose `BookFormat.detect(from:)` is `.rtfd` is a book: append it, skip its descendants, and never count its files as files passed over. Say so in the function's doc comment, where it lists what is a book.

About 120 lines of property list and 10 of Swift.

## Tests

A new file `TextMouthProductionTests/DocumentTypeDeclarationTests.swift`, class `DocumentTypeDeclarationTests` (run `xcodegen generate`):

1. For each row of the table, the app's bundle (`documentType(listing:)`) has a Viewer document type at rank Alternate listing the extensions and the types; the RTFD's is a package. And every extension of every `BookFormat` case other than `.audio` (whose types team audiofmt keeps) is listed in some document type, so a format added later without a document type fails here.
2. `UTType("org.w3.ssml")` in the hosted test is declared (not dynamic), conforms to `public.xml`, and is the type of `UTType(filenameExtension: "ssml")`.
3. A folder holding a copy of `rtfd/with-image.rtfd`, a copy of `rtf/headings.rtf`, and a stray `notes.dat` gives exactly the RTFD and the RTF as books, and counts only `notes.dat` passed over; a ZIP of the same (built in the test with ZIPFoundation) imports as two books through `FileImportService.importZip` (see `ZIPImportTests` for how), one `.rtfd` and one `.rtf`, and no book is made of TXT.rtf.

Run `DocumentTypeDeclarationTests`, `ZIPImportTests`, `DAISYPackageImportTests`, `BookFormatTests`, and `ImportAndShortcutPolicyTests`.

## Not yours

`supportedTypes` (done with each format's wiring) and every Swift file but `FileImportService.swift`'s `importCandidates(in:unpacking:)`. The audio document types are team audiofmt's: add nothing among them and change none of their lines.
