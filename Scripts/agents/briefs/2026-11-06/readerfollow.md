# readerfollow: the reader work's own follow-ups (branch `readers/followups-1106`)

Read `Scripts/agents/briefs/2026-11-06/common.md` first. You are `readerfollow`. The November 6 merge recorded these as left to do. Do them in this order, in small commits, each with tests. Items 1 and 2 must change no real file's reading. Item 3 does, and raises a line.

## 1. `MarkdownMarkerWriter` is slow with many pages in one paragraph

20,000 pages in 2 MB took 116 seconds, for any format. Find the quadratic step and make it linear, with byte-identical output: every golden stays as it is. Prove the growth with a test whose bound can't flake on a busy machine, such as comparing work counts, or a time limit far above the linear cost and far below the old one. Check the writer's callers for the same pattern.

## 2. DOCX and EPUB adopt `XMLInputGuard`'s start tag limit

`XMLParser` is quadratic inside one start tag, and a hostile file can use that to stall an import. The ODT and Word 2003 XML readers use `XMLInputGuard`, and DOCX and EPUB should too, wherever a part goes to `XMLParser`. Its limit must clear every real file: run the DOCX and EPUB samples through, and say how many. Refuse with the wording each reader already uses for a damaged file. The hostile test reads or throws in well under a second.

## 3. Hidden text the DOCX reader misses

- **`w:vanish` in `w:docDefaults` and in a table style.** ECMA-376 17.7.2 gives the style hierarchy, and 17.7.3 the toggle rule. The reader already follows it through paragraph and character styles.
- **A hidden row:** `w:trPr/w:hidden` is not read, so the row's words are read. Word 2003 XML already skips such a row. Make the two agree, and share the code if they can.

These change what a `.docx` reads, so raise `.docx`'s line in `PageReaderVersions` once, in a commit of its own, with the tests that pin it, and name the differences for any golden. Compare before and after on every `.docx` in `TestData/`, and on LibreOffice's and POI's DOCX test documents if you fetch them. Report how many differ, and that each difference is hidden text.

## 4. `w:sym` in DOCX: wait for the word

A symbol in DOCX (`w:sym w:font="Symbol" w:char="F0B0"`) is dropped today, as Word 97's was, so `0.67 µm` reads `0.67 m`. The `word95` agent is adding one Symbol encoding table beside the parsers. When it's on main, the orchestrator will tell you. Then read `w:sym` through that table: a symbol in a font named Symbol reads the table's character, and one in any other font writes a space, so words don't join. If your branch finishes before that, say so in your report and stop, and the orchestrator will resume you.

## 5. OpenDocument's memory peak

The pipeline peaks at 2.0 GB on a 64 MB part, on an 8 GB Mac. Measure where it goes, with a harness under the lock and `/usr/bin/time -l`, and cut the largest contributor if the fix is contained and no reading changes. If the cost is in a shared stage, such as `HTMLToMarkdownConverter` and SwiftSoup, report the measurements and don't rewrite it. An honest "here's where it goes" is a fine result.

## 6. The iOS plist

The iOS app's plist declares no document types for MOBI and KFX, so "Open in TextMouth" doesn't offer those books there. Add them, with `.azw3`, matching what the Mac declares, and check nothing else on the Mac's list is missing from iOS's unless it's something iOS refuses. `make typecheck-ios` stays at 0 errors and 0 warnings.

## Leave alone

The KFX reader, `tdf135056.odt`'s pages, the rich text table limit, the Word readers (`word95` owns those), anything to do with list numbers or picture descriptions in Word and rich text (both are the user's open questions).
