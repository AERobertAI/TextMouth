# kfxreader: DRM-free Kindle KFX books (FMT52, branch `readers/kfx`)

Read `Scripts/agents/briefs/2026-11-05/common.md` first, and `Scripts/agents/briefs/2026-11-04/readers-common.md` as it says. You are `kfxreader`. Your branch is `readers/kfx`, from `main`: `git checkout -b readers/kfx main`, since your worktree may start elsewhere. The MOBI brief, `Scripts/agents/briefs/2026-11-04/mobi.md`, is the closest model for wiring in a new format: read its "The format and its wiring" section, and follow `TextMouth/Parsers/MOBI*.swift`'s example.

The user, November 4: "small Text Mouth readers for .doc /odt etc might be good for both so formatting extraction is under our control, same for kfx." November 6, on test books: "I do think i have some non drm kfx books I think but they aren't public domain / exceptable for pushed tests."

## The wall: this rule shapes the job

Calibre's KFX plugins are GPL 3, and TextMouth is MIT. **You work only from `KFX-FORMAT-NOTES-2026-11-05.md` (repository root) and the public Ion specification, https://amazon-ion.github.io/ion-docs/.** A different agent read the plugin and wrote the notes in its own words.

- **Never open, read, grep, list, or import** anything under `build/orchestrator/followups1105/kfx-plugin/`, `build/orchestrator/followups1105/kfxstudy-scripts/`, `build/orchestrator/followups1105/calibre9/`, or any plugin file. Don't search the web for KFX code. kfxlib, kfxgen, and KindleUnpack are forbidden. Their scripts and output logs are not a map.
- You may **run** the tools below as black boxes, and study the `.kfx` files they make.
- If the notes are wrong or silent, work it out from real files, write it down, and say so in your report. A fact you found this way is yours to use. If you can't, post a `question` to the orchestrator.

## The tools: real test books

Nothing is installed. Amazon's Kindle Previewer 4.0.4 runs unpacked and calibre 9.18 runs from its disk image, each with throwaway settings. Always go through this script, which takes the heavy-work lock itself:

`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/followups1105/kindle-previewer/kfx_tools.sh`

- `kfx_tools.sh make INPUT.epub OUTPUT.kfx`: EPUB to Amazon's KPF (kept as `OUTPUT.kpf`) to KFX, in about a minute.
- `kfx_tools.sh epub BOOK.kfx OUTPUT.epub`: a KFX back to EPUB, as a yardstick to compare against by hand.

The KFX's contents come from Amazon's conversion, and its outer `CONT` container comes from the plugin. These are ready-made, and all of them are public domain:
- `build/orchestrator/followups1105/kindle-previewer/kfx/alice.kfx` (300 KB, from `TestData/alice.epub`) and `.../out/KPF/alice_epub.kpf`.
- `.../trial/alice-boko.kfx` (1.1 MB), written by a third-party converter called boko, from `SV-stark/ebook-rs` (MIT). It's a second, different producer. Keep it out of the repository unless you find it adds a case the others don't have, and name its source in `samples.tsv` if it goes in.

The notes were checked on `alice.kfx`: following them gives the source EPUB's 30,585 words in the same order, in 902 text units and 19 sections, with headings at several levels. Some of what the notes mark unverified is still unverified: tables, lists, overlapping runs, notes, and multi-container books.

**Keep what you make small.** `TestData/format-samples/kfx/`, with lines in `samples.tsv`:
- Write one small CC0 EPUB with a script under `Scripts/`, holding everything the walk has to meet: headings 1 to 6; bold, italic, and both, including inside a word and overlapping; nested `ol` and `ul`; a table with a merged cell; EPUB 3 footnotes (`noteref` and `aside`); links; an image with alt text; a page list; landmarks; a block quote; a poem with line breaks. Make it into a `.kfx` and `.kpf` with the tool, and commit the EPUB beside them. Look at what Amazon's conversion actually does to each, and put what you learn in your report.
- `alice.kfx` may go in as the larger real file. Add it only if a test uses it.

Previewer's licence allows non-commercial conversion, including works distributed at no charge, so a public-domain or CC0 book is fine to commit. Nothing that isn't goes in the repository.

## The user's own books

The user may copy their own DRM-free KFX books into `build/kfx-private/` in the main checkout. **They are not public domain, so they never enter the repository, a commit, a sample list, a golden, a board message, a log, or your report.** Add a test class, `KFXPrivateBooksTests`, that finds that folder through `#filePath` and skips when it's empty or absent, as it will be in a train's worktree. It reads each book and reports **only counts**: words, headings, pages, and refusals. No title, no author, no words, in passing or in failing. The orchestrator runs it by hand.

## Layers: each one leaves something that works

Commit and queue a train after each. Stop at any layer and the branch must still be mergeable.

1. **Recognize and refuse.** A new `BookFormat` case `kfx`, raw value `"kfx"`, display name "Kindle Book (KFX)", extensions `kfx`, `kfx-zip`, and `azw8`, wired in as the MOBI brief shows, in both apps, with `Info.plist` document types. The bytes decide (part 3 of the notes), checked before anything else, on every container of a set:
   - `DRMION`, or a voucher in a set: "This Kindle book is copy-protected, and TextMouth can't read copy-protected books." Reuse MOBI's exact sentence and its type (`grep` it), so there is one wording. Nothing may ever try to decrypt.
   - A `.azw` file holding KFX or `DRMION` bytes: Kindle's apps name KFX books this way. Route it by content: protected is refused as above, `CONT` goes to this reader. Today it probably fails as a broken MOBI. Fix that with a test. Touch `MOBIParser` only for this, and tell the orchestrator.
   - Until the walk exists: "This Kindle book is in the newer KFX format, which TextMouth can't read yet." The layer ends here if nothing else fits.
   - `.kpf` (a ZIP with a `.kdf`): "This file is a Kindle Create package, which TextMouth can't read yet." Don't read it; it's a later item.
2. **Ion, symbols, and the container.** Binary Ion as far as the notes' part 5 asks, the local symbol table, the `CONT` layout, and the entity table, with every offset and length checked. Tests build their Ion by hand with a small writer in the test target.
3. **The walk.** Metadata (title, author, language), the reading order, sections, storylines, and text, written as HTML for `HTMLToMarkdownConverter`, as `readers-common.md` says. Emphasis from style runs, counting offsets in Unicode code points, not UTF-16. Lists and tables as they turn out in real files. An image reads its alt text, as the EPUB reader does. Fixed layout, print replica, comics, magazines, children's books, and notebooks are refused from the marks in part 10 of the notes: "This Kindle book has no flowing text to read, such as a comic or a print replica, so TextMouth can't read it."
4. **Navigation.** Chapters and headings as the EPUB reader makes them, through `MarkdownHeadingAnnotation`: read how `EPUBParser.prepareBook` and `MarkdownCacheService` do it. The book's own headings first, as the notes rank them. The print page list becomes pages at its exact words. `APPROXIMATE_PAGE_LIST` is machine-made and is not pages. Add a `.kfx` line to `PageReaderVersions` at "1.0.0" only if pages exist, with the tests that pin the lines.
5. **Sets.** `.kfx-zip`, built in your tests with ZIPFoundation, with its caps. A `.kfx` with a sibling `.sdr` folder: read the book's metadata from it when the main file lacks it, within limits, and never follow a link outside. A container holding no text, such as a metadata-only file: "This file holds only part of a Kindle book. Open the book's main .kfx file." Say what's left of the Kindle apps' folder forms.

**Cancellation:** ask `ImportCancellation.throwIfCancelled()` in the walk, once it's on main (`git grep throwIfCancelled main`). It's on another branch for now. If it hasn't arrived by your last layer, say so.

## What a listener hears

KFX is a book format, like EPUB, so **the same book must read the same as TextMouth's own EPUB reader reads its source EPUB.** That's your main test, and it needs no outside tool: for each sample with its EPUB beside it, compare the reading text (`MarkdownDocParser.parseChapter`'s, not the Markdown) of both, word by word and in order, and compare their headings. List each difference by name, and each named difference gets a line in your report: never a looser comparison. Notes read where the book's reading order puts them, matching what the EPUB reader does with them. Say what happens.

Words are what matters most: a dropped paragraph, a doubled caption, or a joined word is worse than any missing feature. Check that emphasis marks are never spoken, and that a line break in a heading such as "CHAPTER I.\nDown the Rabbit-Hole" reads as words with a space.

## Hostile files

As `readers-common.md` lists, each throwing cleanly in well under a second: truncation at many lengths, every offset past the end, counts at their maximum, Ion nested deeply (a depth cap and no recursion on a depth the file controls), a storyline or `$608` reference that cycles, a text index out of range, style runs and positions out of range, duplicate fragment ids, a symbol id past `max_id`, a huge declared list, a ZIP bomb in a `.kfx-zip`, and a fixed-seed byte-flip run over each real sample. Bound everything a file can make large, including the total walked nodes and the HTML written.

## Format, versions, and files

- **An older TextMouth can't read a library index holding a book of a new format.** Update `OnDiskContractTests.testEveryBookFormatIsSavedUnderItsOwnName` deliberately, with a comment. The orchestrator raises the version's MINOR and writes the caution. Change no version yourself.
- **Yours:** `TextMouth/Parsers/KFX*.swift`, one concern per file; `TextMouthProductionTests/KFX*Tests.swift`; the script under `Scripts/`; the samples; the format's wiring.
- **Others are working in** `RTF*`, `DOCXParser*`, `WordDocument*`, `CompoundFile*`, and `ODT*`, and `PageReaderVersions`, `samples.tsv`, and `TextPipelineFixtures.formatSampleNames` see one-line conflicts that the orchestrator resolves at merge.
- **Train classes:** your own, plus `OnDiskContractTests,PagesUpgradeTests,DocumentGoldenTests` and the `import` area.

## Your report

Write it to `build/orchestrator/followups1105/kfxreader-report.md` and make it your final message, at most 40 lines:
- The layers finished, and what's left.
- The comparison with the EPUB reader, by sample and by named difference.
- What Amazon's conversion did to each feature in your sample book.
- What the notes got wrong or left out.
- Every refusal and its sentence.
- What you couldn't verify.
- The documentation each change needs.
