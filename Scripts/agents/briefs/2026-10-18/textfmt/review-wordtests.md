# textfmt-rvwordtests: Word template tests that can fail (review item 16)

Slug `textfmt-rvwordtests`, branch `textfmt/rvwordtests` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first, then `TextMouthProductionTests/WordTemplateImportTests.swift` whole.

## The problem

The tests cannot fail: no .dotx, .docm, or .dotm sample has a heading style, so `headingLines == []` pins nothing (around 29-35); and the macro test's `vbaProject.bin` is stored, and `ArchiveEntryReader.read` checks no checksum, so a reader that opened the macro project would import the same (around 103-121).

## What to do (tests only; no app change)

1. Make a .dotx, a .docm, and a .dotm in the test from a real heading-styled .docx in TestData (`test_book.docx` or `alice.docx`: check which has Heading styles), copied, with the main part's content type in `[Content_Types].xml` changed to each form's (`application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml`, `application/vnd.ms-word.document.macroEnabled.main+xml`, `application/vnd.ms-word.template.macroEnabledTemplate.main+xml`; ZIPFoundation in `.update` mode), renamed. Each imports as `.docx` with exactly the .docx's headings (compare `headingLines` with the plain .docx's, and pin the first few by name).
2. The macro test: give the .docm a `word/vbaProject.bin` entry that throws when read: compressed (deflate) with its compressed bytes damaged so that inflating it fails. First assert in the test that `ArchiveEntryReader.read` of that entry throws. Then the import succeeds with the same headings and text as the copy without it, so the reader never opened it. Add its relationship in `word/_rels/document.xml.rels` as today.
3. Keep the tests of the six samples, but pin what they really show (their text), and say in a comment that they hold no heading styles.

Run `WordTemplateImportTests` and `DOCXStructureTests`. Show each new test fails when it should: for the macro test, say in your report what you changed temporarily to see it fail (for instance, reading every entry), and that you put it back.
