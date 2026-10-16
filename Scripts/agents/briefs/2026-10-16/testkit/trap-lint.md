# testkit/trap-lint: a linter for the lines a branch adds to the tests

Slug `testkit-trap-lint`. Branch `testkit/trap-lint`, made from `team/testkit`. Python 3 standard library only. **You build nothing.** Read `teams-common.md`'s worker's part first.

## Why

The user sees a crash dialog for every test host that aborts, and the rules say: no test may trap (no unguarded subscript, force unwrap, over-fulfilled expectation, or unowned capture of a released object), none may play sound aloud or record from a real microphone, none may touch the user's real library. Today only a person reading a diff checks that. A script can check the common cases in seconds, on exactly the lines a branch ADDS, so it needs no baseline and old code never complains. Every lead and worker of every team can run it before a build and at review.

You also build the diff-lint engine that a later task (`testkit-a11y-lint`) reuses for the app's SwiftUI sources, so the engine and the rules are two separate files.

## Files you create

1. `Scripts/test/difflint.py`, the engine (importable from a script in the same folder; every function commented):
   - `added_lines(base, paths)`: the lines added since the merge-base of `base` and `HEAD`, in the given paths: `git merge-base <base> HEAD`, then `git diff -U0 --no-color <merge-base> -- <paths>` (this includes staged and unstaged edits), plus every line of the untracked files (`git ls-files --others --exclude-standard -- <paths>`). Returns `{path: set of line numbers}`. Parse the `@@ -a,b +c,d @@` hunk headers; a hunk with d == 0 adds nothing.
   - `mask_swift(text)`: a small lexer returning, per line of the whole file, two views: `code` (string-literal contents and comments replaced by spaces, so a `!` inside "Finished!" or a comment never matches) and `code_with_strings` (comments masked only). It must handle `"..."` with escapes, `"""` multi-line strings, `#"..."#` raw strings, `//` and nested `/* */`, and keep every line's length and number. State is tracked across the whole file, not just added lines.
   - `Rule(name, level, pattern, message, view='code', unless=None)` with levels `ERROR` and `REVIEW`; `unless` is an optional function of (lines, index) that excuses a hit from context.
   - `lint_file(path, text, rules, only_lines=None)`; a trailing `// lint-ok: <reason>` comment (reason required) on the SAME line suppresses a hit, and the suppression is counted in the summary.
   - `report(hits)`: prints `path:line: ERROR rule-name: message`, then the source line indented by 4 spaces, and at the end one summary line, `N errors, M to review, K suppressed`. Plain words, no color, no emoji (the reader uses VoiceOver and a braille display).
   - `main(rules, default_paths, argv)`: the shared command line: `--base REF` (default `main`), `--paths P ...` (override the default paths), `--all` (every line of every file under the paths, not only added lines: an audit; prints the summary and per-rule counts and exits 0), `--strict` (REVIEW hits also fail), `--selftest`, `-h`. Exit status 0 when there is no ERROR (and, with `--strict`, no REVIEW), 1 when there is, 2 for a usage or git problem.
2. `Scripts/test/trap-lint.py`: the rules for tests; default path `TextMouthProductionTests`; `--selftest` with canned Swift snippets (one that must hit and one that must not, per rule, including the string and comment cases and a `lint-ok`).
3. `Makefile`: nothing (the lead adds targets later).

## The rules (names are part of the interface; tune patterns on the real code, see "Measure")

ERROR (a certain trap or a broken rule):
- `try-bang`: `try!`.
- `as-bang`: `as!`.
- `crash-call`: `fatalError(`, `preconditionFailure(`, `precondition(`, `assertionFailure(`, `assert(` (a Swift `assert` traps in a Debug build), `exit(`, `abort(`.
- `force-unwrap`: a `!` that follows an identifier character, `)` or `]` and is not part of `!=` (`foo!.bar`, `list.first!`, `try XCTUnwrap(x)!`); not a leading negation (`!isEmpty`).
- `unowned-capture`: the word `unowned`.
- `real-library`: in the `code_with_strings` view, `NSHomeDirectory()`, `homeDirectoryForCurrentUser`, `getpwuid`, a literal `"~/`, or the literal `.TextMouth"` (the user's live library; tests use the sandbox `TextMouthRuntime` gives them).
- `real-microphone`: `AVAudioRecorder(`, `AVCaptureDevice.requestAccess`, `AVCaptureDevice.default(for: .audio`.
REVIEW (suspect; a person decides):
- `literal-subscript`: an integer-literal subscript (`items[0]`, `rows[1]`) unless one of the 8 lines above (code view) mentions `isEmpty`, `.count`, `XCTUnwrap`, `guard `, `indices`, or `XCTAssertEqual(...count`.
- `iuo-declaration`: an implicitly unwrapped optional declaration (`var window: NSWindow!`).
- `remove-first-last`: `.removeFirst()`, `.removeLast()`, `.popLast!` without `isEmpty` or `.count` mentioned in the 8 lines above.
- `fulfill-without-guard`: a `.fulfill()` call when the 30 lines above do not mention `assertForOverFulfill` or `expectedFulfillmentCount` (an expectation fulfilled twice aborts the host).
- `main-sync`: `DispatchQueue.main.sync` (deadlock when already on the main thread).
- `blocking-wait`: `.wait()` with no timeout.
- `real-sound`: `NSSound(`, `NSSound.beep`, `AVAudioPlayer(`, `AVPlayer(`, `AVAudioEngine()` followed within 30 lines by `.start()`, `.speak(` on a synthesizer (a test must never play aloud; fakes and `write(...)` buffer callbacks are fine).

## Measure before you finish

Run `python3 Scripts/test/trap-lint.py --all` and look at the per-rule counts. Known counts in `TextMouthProductionTests` on main: `try!` 2, `as!` 0, `unowned` 36, `fatalError(` 0, `precondition*` 8, `[0]` 433. For each ERROR rule, read the hits: a rule whose hits on existing code are mostly false positives must be refined (this is how you tune patterns), but a REAL hit in existing code stays (the audit is meant to show it). In your report give the per-rule counts, and list the real findings (file:line, one line each) so the lead can pass them on. Do NOT edit any test file.

Then prove the added-lines mode: in the scratchpad, create a branch-less check by writing a temporary untracked Swift file under `TextMouthProductionTests/` containing one hit per rule (delete it afterwards), run the linter with no `--all`, confirm it reports exactly those lines and nothing else, and that it exits 1.

## Commits

1. `difflint.py` with its selftest (`python3 Scripts/test/difflint.py --selftest`: masking, hunk parsing on a canned diff, suppression).
2. `trap-lint.py` with its rules and selftest (`python3 Scripts/test/trap-lint.py --selftest`).

## Report (at most 15 lines)

Branch; commits; per-rule counts from `--all`; the real findings; how long `--all` takes; what you could not verify.
