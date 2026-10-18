# textfmt-goldens: the new formats' samples in the document goldens and the import fuzz

Slug `textfmt-goldens`, branch `textfmt/goldens` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## Why

TextMouth keeps a readable golden file for each document in TestData (`DocumentGoldenTests`, recorded by `Scripts/test/update-goldens.sh`), so a later change to a reader shows up as a named difference, and an import fuzz (`ImportFuzzTests`, run by `Scripts/test/import-fuzz.sh`) that damages a copy of each document in a dozen seeded ways and checks every import finishes, refuses cleanly, or gives a book that loads. Both take lists of TestData file names. This task adds the new formats' samples to both lists, records the goldens, sweeps the samples once with the fuzz, and places the team's new test classes in `Scripts/test/areas.conf`.

## Read first (by line range)

- `TextMouthProductionTests/DocumentGoldenTests.swift` (whole, 186 lines).
- `TextMouthProductionTests/TextPipelineFixtures.swift` lines 58-90 (`testDataBookNames`, `optionalTestDataBookNames`, `testDataBooks()`).
- `TextMouthProductionTests/DocumentDump.swift` lines 29-60 and 140-150 (`currentMacOSVersion`) and 245-260.
- `TextMouthProductionTests/ImportFuzzTests.swift` lines 20-90 and 185-230, and `TextMouthProductionTests/ImportFuzzMutator.swift` lines 105-135.
- `Scripts/test/update-goldens.sh -h` and `Scripts/test/import-fuzz.sh -h` (run them; read their output, not their source).
- `Scripts/test/areas.conf` lines 1-21 (its rules) and the `[import]` area.

## What to build

1. **The samples' list**, in `TextPipelineFixtures`: `formatSampleNames`, the paths inside TestData of the samples the goldens record, one per line in the source: every file and folder sample in `format-samples/` for rtf, rtfd (the two .rtfd folders), doc, dot, dotx, docm, dotm, odt, ott, wordml, webarchive, ssml, and dtbook (`harbour-standalone.xml` and the `nimas-style-package` folder), but not `rtf/headings-source.html`, which is only where the others came from. A sample that must import under another name (the WordML sample imports only as an .xml file) is listed with that name in a small mapping beside the list, and is imported from a copy so named in a sandbox folder; every other sample is imported where it lies, as the other goldens are, which never changes it.
2. **Golden names.** A golden's name is the sample's path inside `format-samples` with each "/" written as "__" (two underscores), such as `rtf__headings.rtf.golden`, so `record(_:named:)` still writes only plain file names. `testEveryGoldenFileHasADocument` knows these names.
3. **macOS-dependent goldens.** What textutil reads (rtf, rtfd, doc, dot, odt, ott, wordml) comes from macOS's own readers and may change with macOS, as a PDF's text does: those samples are compared only on a Mac of the same major macOS version, with the PDFs' rule (`macOSVersion: DocumentDump.currentMacOSVersion`, and the same skip sentence naming them). The others (dotx, docm, dotm, webarchive, ssml, dtbook) are compared everywhere.
4. **Record** the goldens with `BBS_AGENT=textfmt-goldens Scripts/test/update-goldens.sh --derived-data <your build folder>`, then read every new golden: each must show the sample's real headings, title, author, and words. A golden that looks wrong (a missing heading, a wrong title, a word read as a file name) is a bug: post it to `textfmt-lead` with the file and what is wrong, and do not commit that golden.
5. **The fuzz.** `ImportFuzzMutator`'s lists: the ZIP-based new extensions (dotx, docm, dotm, odt, ott) join `zipExtensions`; rtf, ssml, and xml join `textExtensions` (an XML or RTF file is text, damaged as text is). A .doc, .dot, or .webarchive takes the default mutations. `ImportFuzzTests` takes the format samples that are single files by default (not the .rtfd and NIMAS folders, whose bytes the mutations cannot damage as one file; say so), writes each damaged copy under its last path component, or its import name from item 1, and its case ID names the path. Then sweep only the new samples once: `Scripts/test/import-fuzz.sh --docs <the new samples, comma-separated> --derived-data <your build folder>`. A crash of the test host or a violation is a finding: post each to `textfmt-lead` with its reproduce command, and report it; do not fix the readers.
6. **Areas.** `python3 Scripts/test/run-area.py --unassigned` lists the test classes no area names: place each new one in `[import]` (`TextutilConverterTests`, `TextutilHTMLStructureTests`, `TextutilSourceCheckTests`, `TextutilImportTests`, `XMLDocumentSnifferTests`, `DTBookImportTests`, `WordTemplateImportTests`, `WebArchiveReaderTests`, `SSMLReaderTests`, `WebArchiveAndSSMLImportTests`, `DocumentTypeDeclarationTests`, and `DocumentByteLimitTests`), in the area's order, and run `--unassigned` again until it lists none of them.

## Tests

`DocumentGoldenTests` must pass with the new goldens on this Mac; `ImportFuzzMutatorTests` must pass; run both, and the fuzz sweep as above, and report the sweep's closing counts line.

## Not yours

The readers and the import: a wrong golden or a fuzz finding goes to `textfmt-lead`. No `*.md` file.
