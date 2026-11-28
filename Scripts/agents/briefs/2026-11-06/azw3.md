# azw3: Kindle books in KF8, the .azw3 format (branch `readers/azw3`, FMT48)

Read `Scripts/agents/briefs/2026-11-06/common.md` first. You are `azw3`. You own `TextMouth/Parsers/MOBI*.swift`, new KF8 files beside them, and their tests.

The user, November 4: "Also I want on the todo for parsers for importing drm free .mobi, .azw3, and .kfx books to at least import them and convert them to the intermediate reading format." MOBI 6 and KFX are done. Today a book that is all KF8 throws `MOBIError.kf8Only`: "This Kindle book is in the newer KF8 format, which TextMouth can't read yet." Read it instead, in both apps.

## What to read

- `FORMAT-LIBRARIES-RESEARCH-2026-11-04.md`, Part 2, by line range (`grep -n "AZW3\|KF8"`).
- The MOBI reader on main, all of `TextMouth/Parsers/MOBI*.swift`: the container, the headers, PalmDOC and HUFF/CDIC text, EXTH, the index reading, and the refusals. Reuse them. KF8 has the same container, at version 8.
- **The map:** foliate-js's `mobi.js` (MIT, `johnfactotum/foliate-js`). It reads MOBI 6 and KF8. Read it as a map of the algorithm, never to copy. If a function of yours ends up close to one of its, say so in the comment and your report. calibre's, KindleUnpack's, and libmobi's code are forbidden.

## What to build

1. **A KF8 book reads:** an `.azw3`, and a KF8 file named `.mobi` or `.azw`. Go by the header's version, not the extension. Join each part's skeleton and fragments (SKEL, FRAG, FDST), and follow the `kindle:pos`, `kindle:flow`, and `kindle:embed` links as far as reading needs. Fonts and pictures aren't read, but a picture's description is, as the MOBI 6 reader and EPUB reader do.
2. **Through the shared converter:** your reader writes HTML for `HTMLToMarkdownConverter`, as the MOBI 6 reader does. KF8's parts are XHTML made from an EPUB, so headings, lists, tables, emphasis, and page-break elements should come through. Do what the EPUB reader does with a table of contents (the NCX here) and with chapters. A book's chapters and headings should match its EPUB's.
3. **Refusals stay:** a copy-protected book is refused with today's sentence, and in a hybrid DRM is checked in both halves. A file too damaged to read gets a sentence a listener can act on. `kf8Only` and its sentence go, and so do the docs' mentions, which your report names.
4. **A hybrid file** (MOBI 6 first, KF8 after the boundary EXTH 121 names) is read today from its MOBI 6 half. Read the KF8 half instead if, on real hybrids, it has the same words and at least as many headings, because that half keeps the structure. Then raise `.mobi`'s line in `PageReaderVersions`, once, in a commit of its own. If real files show a reason to stay with MOBI 6, keep it, and say why.
5. **Metadata** from EXTH and the headers, as the MOBI 6 reader does.

## Safety

Everything in `readers-common.md`'s section on hostile files holds. Watch these especially:
- Fragments' insert positions and lengths that overlap, run backward, or point past a skeleton.
- Index entries whose counts claim millions.
- **Cost that grows with the square.** Inserting fragments into a string one by one is quadratic on a hostile file and slow on a real one. Build each part in one pass. Bound the HTML written. A hostile file reads or throws in well under a second, with growth checks to prove it.
- Text record compression lengths, and trailing data flags, as the MOBI 6 reader treats them.

## Real files

- In the repository already: `azw3/se-the-time-machine.azw3` (Standard Ebooks, CC0), `mobi/pg1952-yellow-wallpaper-kf8.mobi`, and the hybrid `mobi/pg8121-ghosts-hybrid.mobi`.
- **Make more, as a black box:** `bash build/orchestrator/followups1105/kindle-previewer/kfx_tools.sh azw3 INPUT.epub OUTPUT.azw3`, and `... hybrid INPUT.epub OUTPUT.mobi`, run calibre's converter from a mounted image with throwaway settings. You may run it. Never read its code. Keep your outputs in a folder of your own under your worktree's `build/` or the scratchpad.
- **The yardstick:** the same book's EPUB through TextMouth's EPUB reader. Compare the words in order, paragraph by paragraph, and the chapters and headings. Do it through `MarkdownDocParser.parseChapter`, because "reads" means the reading text.
- **More real books:** Project Gutenberg offers KF8 as `https://www.gutenberg.org/ebooks/<number>.kf8.images`, and Standard Ebooks offers `.azw3`. Fetch a modest number, 20 or so, politely and one at a time, into a folder of their own, with the matching EPUB where one exists. Gutenberg's terms ask that automated fetching be gentle, so wait a few seconds between files.
- **Add to the repository** only small files with a named licence. A built hostile file is made in test code, not stored.

## Tests

Sample tests through the reader and the whole import path; a comparison with the EPUB yardstick for at least the samples that have one; every refusal; the hostile list; a cancel partway through (`ImportCancellation.throwIfCancelled()` in the main loop, proved by a test that cancels midway, not before the read starts). `make typecheck-mac` and `make typecheck-ios` stay at 0 errors and 0 warnings.

## Report

Add to the common list: the comparison table, book by book (words, chapters, headings), what a KF8 book reads and doesn't, and whether hybrids moved to the KF8 half and why.
