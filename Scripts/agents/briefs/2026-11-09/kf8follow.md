# The KF8 reader's follow-ups (November 9, 2026)

You are `kf8follow`, a Sonnet worker, on branch `readers/kf8-followups`. First read `common.md` beside this file and follow it exactly: it says how to start, check, and report.

TextMouth's own KF8 reader (.azw3, and the KF8 half of a .mobi) merged on November 8, in 0.4.2. Its merge entry in `TODO-2026-09-04.md` ("Kindle books in KF8") lists five follow-ups, and they are your work.

## Read first

- The TODO entry "Kindle books in KF8: .azw3, and KF8 .mobi (FMT48)": how the reader cuts chapters, and the continuation rule.
- In the main checkout's `build/orchestrator/followups1105/`: `azw3check-report.md` (the narrow check, with Pride and Prejudice's false sections and the second licence section), then `azw3-merge-report.md`.
- The KF8 lines of `docs/developer/testing.md`: the tests, the samples in `TestData/format-samples/azw3` and `mobi`, and the fuzz kit.

## The real books

The narrow check read Project Gutenberg's KF8 files of A Modest Proposal (ebook 1080), Pride and Prejudice (1342), and Moby Dick (2701) beside their EPUBs. Those copies are gone, so download them again from gutenberg.org (the KF8 link and the EPUB 3 link of each), each into its own new folder under `build/orchestrator/kf8follow/books/`. Today's counts, which your changes must keep unless a change means to alter them:
- Pride and Prejudice: 66 chapters;
- Moby Dick: 135 "CHAPTER N" sections, the Epilogue, and one licence section;
- `toc-epilogue` matches its EPUB;
- every real book's words equal its EPUB's, in the same order.

To compare without the hosted suite, you may give the fuzz kit's reader program (`Scripts/test/kf8-fuzz`) an option that prints each section's title and its word count.

## The work, in this order

1. **A Modest Proposal reads as 2 chapters, where its EPUB has 3.** The essay's piece has the same title as the Gutenberg header's piece, so the repeated-title case joins the essay to the header. Find a rule that gives the essay its own chapter and keeps every count above.
   - If its KF8 file and its EPUB are each under 500 KB, add both as samples (a `samples.tsv` line each, with source and SHA-256) and to `KF8RealBookTests`.
   - Pin the rule with a book that `KF8Fixture` builds, too.
2. **The licence's first few words are read at the end of the last chapter.** They are in a piece titled with the licence's heading. Make them start the licence's section, and pin it the same way.
3. **Soft hyphens.** `MOBIMarkup.removingSoftHyphens` removes U+00AD in KF8 only.
   - Make it one shared helper.
   - Measure what a soft hyphen does today, with tests where you can:
     - in search: whether "hyphen" finds "hy\u{AD}phen";
     - in braille: what TextMouth's braille translation makes of it;
     - in speech: what reaches the synthesizer.
   - Count the soft hyphens in the MOBI 6 and EPUB samples under `TestData/format-samples`, and in the Gutenberg EPUBs you downloaded.
   - If a soft hyphen changes what search, braille, or speech gives, remove them in MOBI 6 too, and raise `.mobi`'s reader version.
   - Leave the EPUB reader as it is: report its counts and what you measured, since a change there reads every EPUB book again, and the orchestrator decides it.
4. **`ADDED_EXTENSION`** in `Scripts/ios/sync-info-plist.py` does nothing now that the Mac's plist names .azw3. Remove it, and check that `make check-ios-plist` still passes.
5. **The fuzz kit**, `Scripts/test/kf8-fuzz`, was never built or run.
   - Build its reader with `build-reader.py`, through `run_locked.py`, since it compiles the reader.
   - Run `fuzz.py` through `run_locked.py` too, with seed 1 and 2,000 rounds on each of three samples: `se-the-time-machine.azw3`, the `quay-almanac` hybrid, and Gutenberg's KF8 Yellow Wallpaper.
   - Fix any failure in the KF8 tables, the indexes, the record readers, or the decompressors, with a test that damages a book the same way, as `KF8HostileFileTests` does.
   - **If a failure is inside SwiftSoup, `MarkupGuard`, or the HTML-to-Markdown converter, stop fuzzing.** Report the round, its seed, and the top frames of the crash, and go no further with it: don't shrink the file, mutate around it, or search for others like it. That case is the orchestrator's.

## Checks

- One train for the batch: `--areas import`, with the KF8, MOBI, and KFX classes, `PagesUpgradeTests`, `OnDiskContractTests`, `IOSInfoPlistTests`, and every other class your change could touch.
- Run the real books' counts again after your last change.
