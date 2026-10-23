# Brief: the plan for the official 0.2.0 install (October 23, 2026)

You are `plan020`, an Opus agent, on the branch `research/plan020`. You research and plan; you write no app code. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind.

## The request, in the user's words
"I want to install the new version with it as stable as you can make it so also plan any todos requiring breaking changes for my official update to 0.2.0."

The user runs one Mac, with a live library at `~/.TextMouth`, which you must never read or touch. They will install 0.2.0 soon. Its first launch re-reads the library's text books for pages (PG09 and PG16; see "## From pg16 and version" in `AGENT-NOTES-2026-10-04.md` in the main checkout, `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/`). After that, updates should be smooth.

## Find and plan
1. **What 0.2.0 already changes that an older build cannot read:**
   - `BookFormat.braille`;
   - the new optional fields (`brailleTable`, `editedText`, `pageReaderVersion`, the Mac liblouis version);
   - `SkipUnit` "Page";
   - the config.json keys;
   - content.md page markers.

   For each, say what an older build does with it. Check the decoders.
2. **Changes still to come that would break or force a re-read later,** so they are better done before 0.2.0 ships. Look through the open items of `TODO-2026-09-04.md` (main checkout; `grep -n "^- \[ \]" TODO-2026-09-04.md`, then read the candidates by line range) and the code:
   - cache-format bumps;
   - the escaping of source text in content.md (since cache format 3.0.6, text is written as escaped Markdown literals; the user saw every "," and "." escaped in an exported Markdown file). Weigh escaping only what Markdown needs, with a cache-format bump, against leaving it, and say how it would interact with PG16's first-launch compare if both ship together;
   - the content index version (PG14 wants 1.1.0);
   - the transcript.json format;
   - package layout and file names;
   - settings or shortcut defaults that would be renamed;
   - library index fields;
   - anything else with a version or a strict decoder.
3. **Stability.** List the open follow-ups that could lose data, places, or words, or crash, ranked by risk, so the orchestrator can fix the worst before the install:
   - the reader-load race follow-ups;
   - the pages follow-ups;
   - textutil;
   - the cloud;
   - anything else in the TODO's open follow-ups paragraphs.

## Deliverables
1. `PLAN-0.2.0-2026-10-23.md` in the repository root, committed with `git add -f` on `research/plan020`. It holds:
   - section 1;
   - a TODO section draft headed "## Before the official 0.2.0 install", with items V01 onwards in the TODO's item form: what, why, what breaks for an older build, the migration, files, tests, and risks, ordered by when to build them;
   - the stability list.
2. Questions for the user, each with a recommended answer, only where the choice is theirs.

## Rules
- **Setup.** Your worktree is made from main. Run `git checkout -b research/plan020 main`.
- **Commits.** Commit only the plan document. The commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Do not** build with xcodebuild, run tests, push, or touch `~/.TextMouth`.
- **Time-box:** about 40 minutes. Keep it lean: read by line range, and put several patterns in one grep.
- **Others at work.** The team `transcripts` is working on transcripts tonight; plan around its files.

## The report (your final message, at most 30 lines)
- The document's path and commit.
- The V items, one line each.
- The stability list's top five.
- The questions, with their recommended answers.
