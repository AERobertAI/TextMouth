# The fix round of `feature/title-articles` (November 13, 2026)

You are `articlesfix`, a Sonnet worker. You fix what the Opus review of the Leading articles setting asked for, on its branch. First read `common.md` beside this brief and follow it, and `articles.md` beside it for the user's words.

## Start

- In your worktree: `git switch feature/title-articles`, check `git log -1 --format=%h` prints `3b9a8a4f`, then rebase onto local main (`git rebase main`; only `project.pbxproj` conflicts are expected: settle them with `make generate`). Its lead has finished and its folder is gone.
- Read in the main checkout (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/`): the review `build/orchestrator/nov13/articles-review.md` (findings 1 to 7 and "Couldn't settle" a to d); the report `build/orchestrator/nov13/articles-report.md`; the design `TITLE-ARTICLES-RESEARCH-2026-11-13.md` on the branch.

## The work, one commit each, each with a test that fails without it

1. **Finding 1, repeated letters move on** (`TitleTyping.swift:133-139`, `LibraryTitleTyping.swift:86-87`): follow AppKit's rule, as the probe measured it. A new search starts after the selected row (with several selected, the last in list order) and wraps, so a lone match stays put and H, a pause, then H walks through the H's; an extended search ("ha" after "h") starts at the selected row, so it stays on Hamlet; with nothing selected, from the top. Pass the selection and the new-search flag to `firstRow`; replace the tests that pinned "from the top" (`TitleTypingTests.swift:119`, `LibraryTitleTypingTests.swift:232-237`); add H-pause-H and wrap tests. Update question 4's built answer in the design document.
2. **Finding 2, true captions** (`LeadingArticlesSettingsSection.swift:45`, `LeadingArticleWording.swift:38, 44-46`): the languages note only under choices 2 and 3 (or begun "When articles are ignored, …"); choice 3's sentence says the title is found among the H's, not reached by H alone.
3. **Finding 3, each key cheap** (`LibraryView.swift:1402-1430`, `LibraryTitleTyping.swift:77-97`, `TitleTyping.swift:39-59`): build the typed rows once per derived list in `LibraryListCache`, beside the `rowTitle` memo, with each row's texts folded once; fold the typed letters once per key; compare with `hasPrefix`; for a Space, use the claim decided after the last letter (which also settles finding 5). Pin it with a test that a key over 3,000 rows does no per-row folding (count the folds through a test hook, not a timing), and say in the report what a key costs over 3,000 titles before and after (a scratch harness through `run_locked.py`).
4. **"Couldn't settle" (a), the search field:** `take` begins with a guard that the table is the window's first responder (`window?.firstResponder is NSTableView`, macOS only), so letters typed into the Library's search field always reach it; add a hosted test that types into a real window's search field in choices 2 and 3 and finds the text there. If a hosted test can't hold a real search field, say so and pin the guard with a unit test of `take`.
5. **Finding 4, English articles in other languages' books** (`LeadingArticles.swift:456`), the orchestrator's decision: a book whose metadata names one of the listed languages uses that language's articles plus English "the" only (so "An die Freude" and "A ciascuno il suo" keep their first word); a book in English or in no known language uses English's "the", "a", and "an". Test each of the review's four titles, and an English title in a French book ("The Hobbit" still files as Hobbit).
6. **Finding 6, the probe's cost:** `LibraryTypeSelectProbeTests` leaves every train (list it in `Scripts/agents/runner-skips.conf` with its reason, or gate it on its own opt-in variable, and say how to run it on request), and turn its settled findings into assertions where they can be (search after the selection and wrap; letters add up at 1.2 s, not 1.6 s), in a test that doesn't need the probe's defaults writes.
7. **Finding 7:** correct the design document's two statements the probe didn't show, and add a test that the Books rotor lists the shown titles in choice 3.

Leave "Couldn't settle" (b) to (d) for the report, each with what settling it would take.

## Finish

`make typecheck-tests REF=<commit>` before each train (always), one last train with the areas `library,shortcuts,windows,feeds` and every class you touched, and report as `common.md` says (if writes outside your worktree are refused, your final message is the report; otherwise save it as `build/orchestrator/nov13/articlesfix-report.md`), with each finding: what you changed, its test, and whether breaking it fails the test.
