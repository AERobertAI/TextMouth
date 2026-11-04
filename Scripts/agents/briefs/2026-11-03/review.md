# Outside review of an iOS phase 0 team branch (November 3, 2026)

You review one team branch, read-only, for the orchestrator. Read `ios0-common.md` beside this file first: its rules are what you check against. Do not read AGENTS.md, README.md, or the TODO. Your launch message names the team, its branch (`team/<team>`), the base (`integrate/ios-phase0`), and the lead's report (`build/orchestrator/ios0/<team>-lead-report.md`).

The user's words for tonight: "fixing all IOS errors without changing MacOS behavior if possible". The Mac's behavior is what you guard. A Mac change that is not provably the same is a finding, however small.

## What to check, in this order

1. **The Mac projection.** Run `python3 -I Scripts/ios/mac-projection.py integrate/ios-phase0 team/<team> --diff`. For each file it lists with a real change:
   - read every changed line;
   - decide whether the Mac now compiles exactly what it did (a renamed local, a reordered declaration) or something different;
   - list each different line as a finding, with what the Mac does differently.
   A real change the lead's report defends is still a finding unless the behavior is provably the same.
2. **The moves.** Run `git diff --stat -M integrate/ios-phase0...team/<team>`: every file moved into `TextMouth/Platform/macOS/` must show `{… => …}` with no `+` or `-` in its own move commit.
3. **The wrappers.** Run `git diff integrate/ios-phase0...team/<team> -- '*.swift'`. In every `#if os(macOS)` the team added, the Mac branch is the old text, character for character (the projection proves it; check only where it reported a change). Also check:
   - the `#else` branch compiles to sensible iOS code;
   - no `#if` changes which lines the Mac compiles outside its own block (a misplaced `#endif`).
4. **The stand-ins** (new files in `TextMouth/Platform/iOS/`). Each one:
   - starts with its `// Phase 0 stand-in:` comment;
   - keeps the Mac type's name and the signatures shared code calls;
   - holds no `fatalError`, force unwrap, `preconditionFailure`, `@unchecked Sendable`, or `nonisolated(unsafe)`;
   - has the same isolation as its Mac twin (`@MainActor`);
   - throws `IOSUnavailable` where the Mac's does real work;
   - says, in any sentence a person could hear, plainly what is not available.
5. **The tests.** Run `python3 -I Scripts/test/test-diff.py --base integrate/ios-phase0` from a checkout of the branch, or read `git diff integrate/ios-phase0...team/<team> -- TextMouthProductionTests TextMouthTests`. An existing test may change only a path a moved file left, and the lead's report must say so. Any other change to an existing test is a finding.
6. **Wording.** No Mac label, hint, announcement, or message changed. Search the diff's removed lines for quoted strings, and check each still exists on the Mac.
7. **The lead's evidence.** The report's census count for the team's files (0 expected, apart from errors it names as caused by another team's file), `make typecheck-mac`'s result (0 errors, 0 warnings), and the train's result line. You may run one `python3 -I Scripts/ios/typecheck.py --platform ios --census --ref team/<team> --agent review-<team>` yourself. It takes the machine-wide lock and about two minutes. Run it if the report's numbers look wrong.

## How to work

- Work from your worktree with `git -C`. Make no commits, and edit no file; your report is your only output.
- Read diffs file by file, `--stat` first. Do not read whole unchanged files.
- Never read, copy, or write anything under `~/.TextMouth`.

## Your report (your final message)

Write it also to `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/ios0/review-<team>.md`.
- One line with your verdict: ready to integrate, ready after fixes, or not ready.
- **Findings**, most severe first. Each gives:
  - its severity (Mac behavior change, iOS bug, rule broken, or cleanliness);
  - the file and line;
  - what is wrong, in one or two sentences;
  - the fix you suggest.
- What you checked and found clean, in one line per check above.
