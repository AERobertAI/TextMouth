# textfmt-wordtemplates: .dotx, .docm, and .dotm through TextMouth's own Word reader (FMT01)

Slug `textfmt-wordtemplates`, branch `textfmt/wordtemplates` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## Why

A Word template (.dotx), a macro-enabled document (.docm), and a macro-enabled template (.dotm) are the same Office Open XML package as a .docx; only the main part's content type differs (verified in real files). TextMouth's own Word reader (`DOCXParser`) opens fixed paths (word/document.xml, word/styles.xml, word/numbering.xml, word/_rels/document.xml.rels, docProps/core.xml) and never the content types, so it reads all three as they are, with real headings. It reads only those XML parts, so a macro project (word/vbaProject.bin) is never opened and no macro can run. They share the `.docx` case, whose Book Info name stays "Word Document": a template is a Word document, and the listener loses nothing.

What macOS calls them (verified with `UTType(filenameExtension:)`): .dotx is `org.openxmlformats.wordprocessingml.template`, .docm is `org.openxmlformats.wordprocessingml.document.macroenabled`, and .dotm is `org.openxmlformats.wordprocessingml.template.macroenabled`, all system types, so no imported type declaration is needed.

## Read first (by line range)

- `TextMouth/Models/Book.swift` lines 41-64 (`fileExtensions`).
- `TextMouth/Resources/Info.plist` lines 271-286 (the Word document type).
- `TextMouth/Services/FileImportService.swift` lines 2042-2056 (`supportedTypes`, and its comment about .doc, which stays true for `DOCXParser`).
- `TextMouthProductionTests/BookFormatTests.swift` lines 1-32.

## What to build

1. `BookFormat.docx`'s extensions become `["docx", "dotx", "docm", "dotm"]`; the doc comment of `fileExtensions` gains a sentence saying the templates and macro-enabled forms are the same package, read by the same reader, whose macro project is never opened. Touch no other line of `BookFormat` (another task edits `detect(from:)` at the same time).
2. `Info.plist`'s Word entry (`CFBundleTypeName` "Word Document (DOCX)") lists the three extensions after docx, and the three UTIs after `org.openxmlformats.wordprocessingml.document`, as `Alternate` like the rest. Keep its tabs and order.
3. `supportedTypes` appends the three types by identifier (`UTType("…")`), beside the .docx type, with one comment.

About 15 lines. Touch nothing else.

## Tests

A new file `TextMouthProductionTests/WordTemplateImportTests.swift`, class `WordTemplateImportTests` (run `xcodegen generate`), through `importedForTest` from copies:

1. Each of the six samples (`dotx/`, `docm/`, `dotm/`: the synthetic file and the LibreOffice one in each) imports as `.docx` and opens with its headings and text: pin `headingLines` and a phrase of each (read each sample's word/document.xml with ZIPFoundation in the test, or run the test once and pin what the reader shows after checking it against the document by eye; the synthetic files hold "Harbour Notes" as a heading).
2. `BookFormat.detect(from:)` gives `.docx` for each extension in any letter case, and `.doc` still is not `.docx` (the existing test covers it; do not change it).
3. `FileImportService.supportedTypes` holds the three identifiers.
4. The app's own Info.plist (in the hosted test, `Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]]`) lists each extension and UTI in a document type whose role is Viewer. Write the lookup as a small helper (`documentType(listing extension:)`): later tasks will reuse it for the other formats, so put it in `FormatSampleFixtures.swift`'s extension, with a comment.
5. No part of a macro project is read: a copy of `docm/headings-synthetic.docm` given a `word/vbaProject.bin` entry (added with ZIPFoundation, stored, then its stored bytes flipped in the file so that reading it fails its CRC check; first confirm in the test that `ArchiveEntryReader` reading that entry throws) and a relationship to it in `word/_rels/document.xml.rels` (`Type="http://schemas.microsoft.com/office/2006/relationships/vbaProject" Target="vbaProject.bin"`) imports with the same headings and text as the copy without it.

Run `WordTemplateImportTests`, `BookFormatTests`, `DOCXStructureTests`, `DOCXMalformedXMLTests`, and `ImportAndShortcutPolicyTests`.

## Not yours

Everything about .doc and .dot (another task), and `DOCXParser*.swift`, which needs no change; if you find it reads the content types or the macro part after all, stop and post a finding to `textfmt-lead`.
