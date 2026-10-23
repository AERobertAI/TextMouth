# Brief: a changelog, and the version policy (October 23, 2026)

You are `changelog`, a Sonnet agent, on the branch `release/changelog`. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## The request, in the user's words
"Can you also make a Changelog in the user facing docs and a agent polacy to update the version number more consistantly, like every day of bug fixes or small non breaking features during the beta add 1 to the third part and every non backwards compadable change put in the second part (I think that might actually be for the major first number? but this is a beta and will stay so for a long time)."

## What exists (main, be385e1a)
- `docs/user/whats-new.md`, made on October 21, holds a "0.2.0 (October 21, 2026)" section. It is linked from `README.md`.
- `Scripts/set-version.sh <version>` (and `make set-version VERSION=x.y.z`) sets `MARKETING_VERSION` in `project.yml` and runs `xcodegen generate`, with a `--selftest` that `make check-selftest` runs.
- `docs/developer/building.md`'s "Versions" section and a line in `AGENTS.md`'s "How the orchestrator works" describe the October 21 procedure (minor for a feature set, patch for a fix-only install). The user's policy now replaces it.

## Decisions (settled)
1. **The changelog.** Rename `docs/user/whats-new.md` to `docs/user/changelog.md`, titled "Changelog", with `git mv`.
   - A short opening line says what it is: every version, newest first, and what changed for the user.
   - Keep the 0.2.0 section as it is.
   - Add a line for 0.1.1, the version before October 21, 2026, saying only that it was the first beta version and that its changes are not listed.
   - Update every link: `README.md`, building.md, AGENTS.md, and any page that names What's new (`grep -rn "whats-new" README.md docs AGENTS.md`).
   - Headings and lists only, written plainly for VoiceOver and a braille display.
2. **The version policy,** in the user's words above, written into building.md's "Versions" section and AGENTS.md's orchestrator line:
   - During the beta, which will last a long time, the version is `0.MINOR.PATCH`. MAJOR stays 0 until the user calls TextMouth released (1.0).
   - **PATCH** goes up by 1 for each day on which main gains bug fixes or small backward-compatible features. That is one bump per day, made after the day's last merge, before the user's next install.
   - **MINOR** goes up by 1, with PATCH back to 0, for any change that is not backward compatible:
     - a TextMouth one version older cannot open the library;
     - every book is read again (a cache-format change);
     - a stored format changes;
     - a setting, shortcut, or file is removed or renamed.

     A day that has such a change bumps MINOR instead of PATCH.
   - **Each bump** adds a dated section to the changelog, with one plain sentence per change. A MINOR section says first what an older TextMouth can no longer do with the library.
   - **The orchestrator** makes the bump, with the script.
3. **The script.** `Scripts/set-version.sh` gains `--patch` (0.2.0 to 0.2.1) and `--minor` (0.2.3 to 0.3.0), which compute the next version from `project.yml`. The explicit form stays.
   - Add selftest cases for both, including a refusal when `project.yml`'s version is malformed.
   - Add Makefile targets `make bump-patch` and `make bump-minor`, listed in `make help`.
4. **Do not bump the version now:** the orchestrator bumps it at the end of today's merges, by this policy.

## Rules
- **Setup.** Your worktree is made from main. Run `git checkout -b release/changelog main`.
- **Builds.** Do not build the app.
- **Commits.** Small commits, each message ending with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Comment the script as the other scripts in `Scripts/` are commented.
- **Paths.** Use literal paths in every `rm`.
- **Never** push, merge into main, or touch `~/.TextMouth`.
- **Others at work.** The team `transcripts` is working on transcription code tonight. Touch none of its files: Swift code, and `docs/user/transcribing.md`.
- **At the end,** run `make check-selftest`, which builds nothing, and report its last lines.

## The report (your final message, at most 15 lines)
- Each commit.
- The policy's wording, as building.md now has it.
- The selftest result.
