# polish2-verify: check the open follow-ups and reviews against main, and write the verified list

- Team `polish2`; lead `polish2-lead`; your task is number 1 on the team's list.
- Your slug is `polish2-verify`. Your branch is `polish2/verify`, made with `git checkout -b polish2/verify team/polish2`. Your worktree may start on an old commit, so branch from `team/polish2` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Keeping the cost down". You build nothing, so skip "Builds".
- Register, joining the team, then mark your task started:

      bbs register polish2-verify --role "Verify open follow-ups and REV10-14 against main" --branch polish2/verify --files Scripts/agents/briefs/2026-10-12/polish2/candidates.md --team polish2
      bbs task move polish2-verify 1 working

- Your charter grants you one exception to "Edit no `*.md` file": you write `Scripts/agents/briefs/2026-10-12/polish2/candidates.md`, and nothing else.

## Why
The TODO's "Still open after …" lines are never struck when a later merge fixes an item. The first polish round spent most of its effort learning which items were still open: about 30 checked to find 8. You check them all once, quickly, so the lead can choose 6 to 10 to fix.

## What to read
In `TODO-2026-09-04.md` on your branch, by line range, once each. Read nothing else in the TODO.
1. **Lines 3052 to 3152.** The paragraph beginning "**Open follow-ups noted on October 3 afternoon and evening**", then every "Still open after …" line, with the few "Also found …" and "Noticed by …" lines among them, through "Still open after the polish-team merge". The lines are long: read them in four ranges (3052–3090, 3091–3115, 3116–3135, 3136–3152).
2. **Lines 3753 to 3969:** REV14, REV13, REV12, REV11, and REV10, in that order. Each names its reviewers' numbered findings, then says which were "done by" an agent and its merge. Only a finding that no sentence calls done is a candidate. A finding sent "to docsNN" is the orchestrator's: skip it.

## Skip without checking
List each in the last section of the file, a few words each, so the lead sees you saw it.
- **Closed by the first polish round.** Its merge entry and line 3152's last sentence close these: the Remove Download refusal said once (#2094); the Headings sheet's rows after a speed change; Create's folder announcement; the Shortcuts and Sound Effects Reset to Defaults announcements; `Book.isUnopened` and `Library.booksInFolderTree(_:)` (REV07); the Continue button's time for a finished book; the Edit menu's keys matched by stroke (#1551); Reset to Global Settings naming pitch; #1857's first slice; #1542; #1552; #1553 and the Record hints' fixed keys; #867; `showEditedMetadata`'s guard; Release Media Controls' silence; `pause(playingPauseSound:)`; "0 of 1 books processed"; Feed Info's folder help and its "takes effect" note; #1816's hint; the Remove menu's title for feed items; #1593; #1695; Speak Info's "In reading list"; the edit bar's Deselect All with no books; the summary bar calling episodes books; and the recorder taking Command-Q.
- **The t6d team's lanes:** `PlaceRelocator`, `TextAnchor*`, `PatienceDiff`, `FineWords`, `SkippedHeading` and the skips in `Book`, `MarkdownCacheService`, `LibraryPersistenceService.saveContentAnalysis`, `MachineLocalPaths`, the reader's `showLoadedContent`, and T06's branches D and E. Lines 3143, 3146, 3149, and 3150 are mostly theirs; check only an item there that names none of these.
- **The board and the orchestrator's scripts:** `.claude/skills/agent-bbs/` and `Scripts/agents/` (line 3151 is all board).
- **Manual-only items:** P09, T10, and A01. Also **FR02**.
- **What `humanQuestions/2026-10-12.md` asks the user:** the Continue button's "Finished", the Shortcuts Reset alert's wording, Delete Feed…'s in-use refusal, and #2077.
- **Documentation only:** an item whose whole fix lies in a `*.md` file (README, ARCHITECTURE, a research document). A wrong comment in a `.swift` file is not documentation: check it like any item.
- **Not a defect:** the load-sensitive tests named under "Builds" in `teams-common.md`, and design notes that only describe a choice.

## How to check
For each item not skipped, make one check against the code on your branch, which is main's:
- Usually that is one `grep -rn -E` for the function, string, or key the item names, in `TextMouth/` or `TextMouthProductionTests/`, ending in `| head -4`. Or it is `sed -n` of at most 20 lines around a hit.
- Decide: still as the item says (open), or changed (fixed). For a fixed item, name the commit when `git log -S'<string>' --oneline -3 -- <file>` finds it at once; otherwise name the file and line that show it fixed.
- Spend at most about two calls on an item. If two calls do not settle it, put it under "Too large for one task" or "Needs the user", marked "unsettled:" with the reason.
- **Batch:** check 6 to 10 items in one Bash call, and make independent calls in the same response. For example:

      for p in 'folderHasContents' 'LibraryInfoSpeechDelegate' 'WhereAmIDelegateHelper'; do echo "== $p"; grep -rn -E "$p" TextMouth TextMouthProductionTests | head -4; done

- Read code only by line range. Never open a whole file.

## What to write
`Scripts/agents/briefs/2026-10-12/polish2/candidates.md`. Write it as you go, appending after each range you finish, so nothing is lost if you are stopped.
- Start each item's line with its line number in the TODO (`L3091`), then its identifier when it has one (`#1377`, `REV13 reviewlibrary (4)`), so the orchestrator can find and strike it.
- Where one TODO sentence lists several defects, split them into separate items.
- One item a line, under about 300 characters.

The layout:

    # polish2 candidates, verified against main <short hash>, October 12

    ## Still open, one right answer
    - L3152 #1857 [tests] next slice: … Files: TextMouthProductionTests/….swift (lines). Fix: … Size: S. Test: …

    ## Still open, needs the user
    - L31nn … Question: … Recommended: …

    ## Already fixed
    - L31nn … Fixed by <hash> <subject>, or: <file:line> shows it.

    ## Too large for one task
    - L31nn … Why, in a few words.

    ## Skipped without checking
    - L31nn … Which rule: polish round, t6d, board, manual, humanQuestions, documents, not a defect.

In the first list, tag each item with one kind, which is how the lead chooses:
- `[listener]`: what VoiceOver says, keyboard access, a wrong state shown, a control that does nothing, a crash risk in the app;
- `[correctness]`: a wrong result the listener may not notice at once;
- `[tests]`: a test that can trap or race;
- `[comment]`: a wrong comment in a `.swift` file;
- `[refactor]`: duplication or needless work.

Give each a size: S (up to 50 changed lines besides tests), M (up to 150), or L (more, which belongs under "Too large"). Name the test that would pin it, in a few words, or "none" for a comment.

## Finish
1. Commit only the file, with `git add -f`, in one commit with this subject, and the `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` line at the end of its message:
   `List the polish2 candidates, verified against main`
2. Post the commit to the team's channel (`--to team:polish2 --tag commit`).
3. Move your task: `bbs task move polish2-verify 1 review --note "N open, N user, N fixed, N large, N skipped"`.
4. Post `done: polish2/verify` to `polish2-lead`, and release your claims.
5. Reply with a report of at most 15 lines: the branch; the commit's hash and subject; the count in each list; and anything you could not settle.

## Do not
- Change any code, test, or other file.
- Build, or run tests.
- Read `AGENTS.md`, `README.md`, `ARCHITECTURE.md`, `AGENT-NOTES-*`, or more of the TODO than the ranges above.
