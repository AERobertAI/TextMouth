# Brief: `stable020-contract` (ST04, V02)

- **Slug:** `stable020-contract`. **Branch:** `stable020/contract`, made with `git checkout -b stable020/contract team/stable020`. **Team:** `stable020`, lead `stable020-lead`.
- **Read first:** `Scripts/agents/briefs/2026-10-19/teams-common.md`, its sections "The worker's part", "Rules for everyone", "The board", "Builds", and "Lessons every brief applies". Nothing else of it. For V02, read `PLAN-0.2.0-2026-10-23.md` §1 (lines 19-88) and §2.6 to §2.8 (lines 160-191).
- **Why:** the user installs 0.2.0 as their official build next. ST04 makes the duplicate question say truly what Replace Existing throws away (§3.2 item 4); V02 pins what 0.2.0 writes to disk, so that every later change to it is a deliberate step a review sees.
- **Register with:** `--files TextMouth/Models/ImportDecision.swift,TextMouth/Views/Library/ImportDecisionSheet.swift,TextMouth/Models/Book.swift,TextMouthProductionTests/ImportDecisionQueueTests.swift,TextMouthProductionTests/OnDiskContractTests.swift,TextMouth.xcodeproj/project.pbxproj,Scripts/test/areas.conf`
- **Three commits:** ST04; V02's test class; the comment on `BookFormat.braille`.
- **Disk:** before every build, `df -g /System/Volumes/Data` must show at least 4 GB available; if not, post to `stable020-lead` and wait for an answer (`bbs watch stable020-contract --timeout 240`). Your build folder is `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-stable020-contract`.

## Commit 1: ST04, what Replace Existing throws away
**Today.** Replace Existing (`LibraryViewModel+Duplicates.swift:249-261`) deletes the library's copy's package, to the Trash when "Move to Trash instead of deleting" is on (`FileImportService.removeItemRespectingTrashSetting`), and adds the new copy under a new ID; only its place on the reading list is carried over. Its reading position, bookmarks, settings, an Edit Text change, and a transcript go with the old package. The question (`ImportDecisionWording.duplicateMessage`, `TextMouth/Models/ImportDecision.swift:288-300`) says "Replace the existing copy (updates the .tmb and timestamp) or keep both as separate entries?", and the button's hint (`ImportDecisionChoiceWording.replaceExisting`, `TextMouth/Views/Library/ImportDecisionSheet.swift:188-192`) "Removes the copy already in the library and keeps the new one in its place." Neither says what is lost. Carrying the state over is a follow-up; this commit makes the words true.

**Do:**
1. `duplicateMessage` takes `movesToTrash: Bool`, passed by `init(for:position:total:matchingTitle:movesToTrash:)`, which has it already. The message is three parts:
   - `"“\(newCopy)” matches “\(matchingTitle)”, which is already in your library. Replace the existing copy, or keep both as separate books?"`
   - then `"\n\n"` and, with `movesToTrash`: `"Replacing moves the existing copy to the Trash, with its reading position, bookmarks, settings, and any edit of its text or transcript; the new copy starts from the beginning."`; without: `"Replacing deletes the existing copy, with its reading position, bookmarks, settings, and any edit of its text or transcript; the new copy starts from the beginning."`
   - then, as now, `"\n\nThe copy just imported is incomplete. \(warning)"` when there is a warning.
   Put the two loss sentences in `ImportDecisionWording` as static functions or constants with doc comments, so a test can name them.
2. The Replace Existing hint becomes: `"Removes the copy already in the library, with its reading position, bookmarks, and settings, and keeps the new one in its place."`
3. Doc comments say why (ST04): the question must say what the choice throws away.

**Tests:** `ImportDecisionQueueTests` pins the old message at line 179 and may be changed to the new one (it is the one exact-output test you may change; say so in the commit message). Add, in that class: the message with `movesToTrash: false` (the deleting sentence), the message with a warning (all three parts, in order), and the hint, each pinned exactly. Find any other test or code that quotes "updates the .tmb and timestamp" or the old hint (`grep -rn -E "updates the .tmb|keeps the new one in its place" TextMouth TextMouthProductionTests docs`); change code and tests that quote it, and list in your report any file under `docs/` that quotes it, for the documentation pass (you edit no `*.md`).

## Commit 2: V02, `OnDiskContractTests`
A new file, `TextMouthProductionTests/OnDiskContractTests.swift` (`/opt/homebrew/bin/xcodegen generate`, and commit the regenerated `TextMouth.xcodeproj/project.pbxproj` with it), and one line in `Scripts/test/areas.conf` naming the class in the area that already lists `BookContentIndexTests` (sorted in place). `run-area.py --unassigned` must then print "0 unassigned".

The class pins what 0.2.0 writes to disk, **and only what no existing test pins already**. Before you pin an item, look for an exact pin of it (`grep -rn` the symbol and its literal values in `TextMouthProductionTests`). Where one exists, do not pin it again: name the test that pins it in the class's doc comment, under "Pinned elsewhere". Known ones: cache format 3.0.7 in `BookContentIndexTests`, `MetadataReaderVersionTests`, and `TextAnchorFineWordsTests`; shortcut former names in `MenuKeyShortcutTests` and `ImportAndShortcutPolicyTests`; `SkipUnit`'s cases in `SettingsPolicyTests` and `PageNavigationTests`.

Pin, each against literal expected values (never against the code's own constants), in tests named for what they pin:
1. Every `BookFormat` raw value, in order (`BookFormat.allCases.map(\.rawValue)`, or each case if it is not `CaseIterable`).
2. Every `SkipUnit`, `LibrarySortField`, and `LibraryCategory` raw value.
3. Every shortcut action's saved name (`ShortcutAction`'s raw values), with each action's `formerNames`.
4. config.json's keys: encode the config `ConfigService` writes, with every optional set, and compare its JSON object's key set with a literal set.
5. A library row's keys: encode a fully populated `Book` (every optional field set; use an existing fully populated fixture if a test has one, such as `ContentAnalysisMergeTests`', else build one in the class) as library.json encodes rows, and compare the key set with a literal set.
6. A package record's keys: the same for `BookInfo` made from that book.
7. The package's file names (content.md, the record's file, transcript.json, and every other name `TextMouthPaths` or the package code gives a file in a package).
8. The versions: content index (1.0.0), the `PageReaderVersions` table (each format with pages, and that the rest have none), the reading-text cache (2), the transcript layout (1), the feed index and feed format (1), the text anchor (1), the audio edit list (1), and the cleanup rules (1). Find each constant by its type; pin the value it has now.

Every assertion's message says what changing the value forces, and points at the plan, in this form: `"<what> changed: <what it forces>. See PLAN-0.2.0-2026-10-23.md, V02."` What each forces:
- a `BookFormat` added or renamed: "a TextMouth built before it refuses the whole library";
- a `SkipUnit` renamed: "an older TextMouth reads the saved unit as the default";
- a `LibrarySortField` added or renamed: "an older TextMouth refuses library.json"; a `LibraryCategory` renamed: "the saved category is lost";
- a shortcut action renamed without its former name: "the user's own shortcut for it is lost";
- a config.json key renamed or removed: "the user's setting is lost, and an older TextMouth drops a new key at its next write";
- a row or record key renamed: "that field is lost for every book"; added: "an older TextMouth drops it at its next write";
- a package file renamed: "an older TextMouth no longer finds it";
- the content index version: "every book is indexed again at the next launch"; a page reader's: "every book of that format is read again at the next launch (V05, V07)"; the reading-text cache's: "this Mac's kept reading texts are dropped"; any other: "an older TextMouth refuses or ignores what a newer one wrote".

The class's doc comment says what it is for, in two sentences, and lists "Pinned elsewhere". No test may trap: compare whole arrays and sets, never index into them.

## Commit 3: the comment on `BookFormat.braille`
In `TextMouth/Models/Book.swift`, the comment on `BookFormat.braille` says a TextMouth built before it "keeps the library's file and writes nothing". That is wrong (`PLAN-0.2.0-2026-10-23.md` §1.1): such a build refuses the library, keeping library.json and a copy of it as they are, but still writes each book's package record, which loses the fields it does not know (0.2.0's records of edits and pages, §1.2). Correct the comment to say so, and the same sentence on any other case with it (`grep -n "writes nothing" TextMouth/Models/Book.swift`). Comment only; no code.

## Test classes to run
`ImportDecisionQueueTests`, `ImportDecisionFlowTests`, `OnDiskContractTests`, the import area (`python3 Scripts/test/run-area.py -h` lists the areas), and `python3 Scripts/test/run-area.py --unassigned`. Run `make lint-tests LINT_BASE=team/stable020` before you report.

## Do not touch
Any file not named above, `*.md`, and the transcripts team's files. A failing existing test other than the one named means stop and ask your lead.
