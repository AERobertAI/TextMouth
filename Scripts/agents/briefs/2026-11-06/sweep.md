# sweep: older recorded bugs that a person can still hit (branch `fix/followup-sweep`)

Read `Scripts/agents/briefs/2026-11-06/common.md` first. You are `sweep`. Parts of `readers-common.md` are about readers and don't apply; its builds, tests, board, and rules do.

`TODO-2026-09-04.md` holds 46 lists headed "Open follow-ups noted by ..." (`grep -n "^\*\*Open follow-ups" TODO-2026-09-04.md`, starting near line 3734), written by agents from September 28 on. Nobody has gone back through them. Many have been fixed since without the list being updated, by the October 30 bug hunt among others. Others are still real.

## Step 1: find out what's still true

Read every list, by line range. For each item a person using the app could hit, check today's code and decide: **fixed**, **still real**, or **not worth it** (say why, in a few words). Skip purely internal items: a private copy of a helper, a test's style, a doc line. Don't guess: a claim of "fixed" names the code that fixes it, and "still real" names the line that's still wrong. Keep the table in your report, and send it to the orchestrator as soon as it's done, before you begin fixing: `SendMessage` to `main`, or a `finding` on the board.

Examples of what you'll find, to be checked and not assumed:
- The Search in Book menu item stays enabled for audio books, which ignore it.
- `moveZipBooksToFolder` fails silently on a refused folder name.
- `LibraryView` navigates to a refused rename's path.
- A Markdown book named `content.md` collides with the text cache file name.
- The substitution editor's Test button can use a stale compiled regex.
- The footer says "1 rules".
- Delete and Reset to Defaults have no confirmation or undo.
- Move Book Up and Down do nothing silently.

## Step 2: fix the ones worth fixing

Rank what's still real by what a person loses: lost data first, then something silently not done, then something wrong, then something only awkward. Fix from the top, one bug to a commit, each with a test that fails without the fix. Prove that test by breaking the code on purpose, at least for anything touching data. Aim for many small correct fixes, not a few big ones. Stop at about 25, or sooner if the rest aren't worth the risk.

**Don't take on, and list instead:**
- anything that changes the on-disk format, or what a format reads (no raising of `PageReaderVersions`);
- a change of behavior a person might be relying on, or a new confirmation where the user hasn't asked for one. Say what you'd propose, so the orchestrator can ask them. Delete and Reset to Defaults above are examples: list them.
- a design question, or anything that takes more than about 100 lines;
- files other agents own tonight: see the common brief.

**Wording.** `readers-common.md` says no existing wording changes unless your brief says so. This brief allows it only where the words themselves are the bug, such as "1 rules". A person who reads by VoiceOver hears every sentence, so a new sentence is a full, plain one, and it says what happened and what to do next.

**Accessibility.** The user reads with VoiceOver and braille. A silent failure is worse for them than for a sighted person, because nothing on screen tells them. Where a fix adds a message, make sure VoiceOver gets it the way the app's other messages reach it.

## Keep the machine and the record in mind

The hosted tests go through the train, in small sets of classes, as the brief says. Don't edit the TODO: your report says which items to tick or strike, by their list's line number, and the orchestrator records them.

## Report

The common list, then: the table of Step 1 (counts first, then the items), each fix with its commit and test, and the list of things you'd ask the user.
