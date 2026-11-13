# A batch of the TODO's open items (November 13, 2026)

You are a Sonnet worker. Your launch message names your batch's letter, its name, your branch, and its items. First read `common.md` beside this brief and follow it.

## The user's words

On November 13, 2026: "Ok I want you to keep working through the todos for Text Mouth."

## Your items

- They are in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/nov13/triage-report.md`: section 1 gives each item's evidence (file and line), its fix, and its test, by number; section 2 gives your batch's files, the test classes for your train requests, and the areas.
- The triage was read from main 130f6788 by Sonnet readers, so **check each item in the code before you change anything.** If an item is already fixed, or its evidence is wrong, skip it and say so in the report, with what you found. If its fix would change more than the item says, take the smallest fix that is right and say why.
- **One commit for each item, each with its test.** A test must fail without the fix: break the fix in a scratch copy (or by reading, where only the hosted app shows it) and say so in the report.
- Stay inside your batch's files. A problem you find elsewhere goes on the board as a `finding`, not into your branch.
- If an item changes what a reader makes of a book, raise that reader's version (`PageReaderVersions` or the format's own version constant), and say which books are read again at the next launch.
- If an item adds or changes a stored format, name `OnDiskContractTests` in your train request, and make sure an older TextMouth can still open the library.

## Work in this order

1. Read your items in the report and the code around each.
2. Fix them one at a time, committing each with its test.
3. Type-check (`make typecheck-mac`, `make typecheck-ios`, `make typecheck-tests REF=<commit>`) once for the batch, then one train request naming every class in your batch's list plus any you added.
4. While the train runs, review your whole diff (`git diff main...HEAD`) and fix what you find; request again if you committed.
5. Rebase onto local main, run the full suite on GitHub as `common.md` says, and report.

## Your report

Follow `common.md`'s report. For each item: done, skipped (why), or changed in scope (why); its commit; its test; whether a break fails it.
