# The rule for #1857: test files that fail instead of trapping

Shared by `subs1.md` to `subs4.md`. Written by `fixes-lead` from the rule the polish teams used (`Scripts/agents/briefs/2026-10-12/polish4/liverefresh.md`, which you may read for its worked examples).

## Why
A subscript on a list a test has not proven long enough traps when the list is short, and the trap crashes the whole test host: the user, who uses VoiceOver and a braille display, sees a macOS crash dialog for every aborted test host, instead of one failed test. **An XCTAssert does not stop a test** (unless the class sets `continueAfterFailure = false` in `setUp`; check each class), so an assertion about a count proves nothing about the subscript after it.

## Which lines are at risk
Find the candidates in each file with:

    grep -n -E '[A-Za-z0-9_)?!]\[[^]"]+\]' <file>

and judge each match yourself; many matches are not subscripts (types such as `[String]`, array and dictionary literals, `[weak self]` captures, text inside a string literal). Also judge `.first!`, `.last!`, `try!`, `as!`, `removeFirst()`, and `removeLast()` on a list the code under test made. A subscript is:
- **At risk:** the list was made or changed by code under test (the library's `books`, a parsed `chapters`, a result's `items`, a directory listing, a fetched or decoded array), and nothing before the subscript stops the test when it is short.
- **Safe; leave it alone:**
  - a list the test wrote itself, as a literal, or built by a helper of its own with a fixed number of values (read the helper to be sure), so long as nothing between its making and the subscript can change its length;
  - a subscript after a guard that stops the test (`try XCTUnwrap(list[safe: n])`, or `guard … else { XCTFail(…); return }`), so long as nothing between the guard and it can shorten the list;
  - a dictionary subscript by a key (returns an optional, never traps);
  - text inside a string literal.

## The fix
- `subscript(safe:)` is the shared, read-only helper in `TextMouthProductionTests/CollectionTestSupport.swift`, on `Array`. Use it; do not change it.
- For a value read: `let chapter = try XCTUnwrap(content.chapters[safe: 1], "the book has no second chapter")`, then use `chapter`. For an expression read once in an assertion: `XCTAssertEqual(list[safe: 2]?.title, "…")`.
- Before a write by position, or several reads of one index: one guard line, `_ = try XCTUnwrap(list[safe: n], "…")` (or a binding), after which the test's own subscripts may stay, so long as nothing between the guard and them can shorten the list. A subscript in a loop stays in the loop: guard each pass, or the loop's bound.
- A test that needs `try` becomes `throws` (or `async throws`); change nothing else in its signature.
- A guard's message says what is missing, in plain words ("the library has no first book").
- **Change nothing a test asserts**: no expected value, no message, no test removed, renamed, or reordered, no assertion weakened. Keep every read at the moment it happens now. Keep the comments; update one only if the code it describes changed.
- Add no new warning, no new file, and no helper beyond `subscript(safe:)`.
- When you are unsure whether a line is safe, guard it.

## What to report
For each file: how many matches the grep found, how many you guarded, how many you judged safe and left (and one line on why, by group), and anything you could not decide. Your last result line (`Executed N tests, with S tests skipped and F failures`), and the classes run.

## Before you finish
`grep -n -E '[A-Za-z0-9_)?!]\[[^]"]+\]' <file>` over each file must find only lines you judged safe, or guarded ones below their guards, and nothing new.
