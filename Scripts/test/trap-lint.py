#!/usr/bin/env python3
"""trap-lint: find the lines a branch ADDS to the tests that can crash a test
host, play sound aloud, record from a real microphone, or touch the user's
real library.

The user sees a crash dialog for every test host that aborts. The rules for
tests: no unguarded subscript, force unwrap, over-fulfilled expectation or
unowned capture; no sound aloud; no real microphone; never the live library.
This script checks the common cases in seconds, and only on lines the branch
added (so old code never complains and no baseline file is needed).

Usage (from anywhere inside the repository):
    python3 Scripts/test/trap-lint.py                  # lines added since main
    python3 Scripts/test/trap-lint.py --base team/testkit
    python3 Scripts/test/trap-lint.py --all --counts   # audit all existing tests
    python3 Scripts/test/trap-lint.py --selftest

Exit status: 0 no ERROR (with --strict: no REVIEW either), 1 findings, 2 a
usage or git problem. A hit may be excused on its own line with a trailing
`// lint-ok: <reason>` comment (the reason is required and counted).

The engine is Scripts/test/difflint.py; this file holds only the rules.
"""

import os
import re
import sys

# The engine lives beside this script (and importing it must not leave a
# __pycache__ folder in the repository).
sys.dont_write_bytecode = True
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
import difflint  # noqa: E402
from difflint import ERROR, REVIEW, Rule  # noqa: E402

DEFAULT_PATHS = ["TextMouthProductionTests"]


# ---------------------------------------------------------------------------
# Context helpers used by the rules' `unless` functions
# ---------------------------------------------------------------------------

def mentions_above(lines, index, window, pattern):
    """True when `pattern` occurs on the line at `index` or in the `window`
    lines above it (all in the comment-and-string-masked code view)."""
    start = max(0, index - window)
    return re.search(pattern, "\n".join(lines[start:index + 1])) is not None


def mentions_below(lines, index, window, pattern):
    """True when `pattern` occurs on the line at `index` or in the `window`
    lines below it."""
    return re.search(pattern, "\n".join(lines[index:index + window + 1])) is not None


def guarded_subscript(lines, index):
    """A literal subscript is excused when the 8 lines above show the
    collection's size or emptiness being checked or safely unwrapped."""
    return mentions_above(
        lines, index, 8, r"isEmpty|\.count|XCTUnwrap|\bguard\b|indices")


def guarded_removal(lines, index):
    """removeFirst/removeLast is excused when the 8 lines above look at the
    collection's size or emptiness."""
    return mentions_above(lines, index, 8, r"isEmpty|\.count")


def guarded_fulfill(lines, index):
    """fulfill() is excused when the expectation's over-fulfilment is handled
    within the 30 lines above (a second fulfill() aborts the test host)."""
    return mentions_above(
        lines, index, 30, r"assertForOverFulfill|expectedFulfillmentCount")


def engine_never_started(lines, index):
    """An AVAudioEngine() is excused unless `.start()` follows within 30 lines
    (an engine that is never started is silent), or it is switched to manual
    rendering, which runs offline and makes no sound."""
    if mentions_below(lines, index, 30, r"enableManualRenderingMode"):
        return True
    return not mentions_below(lines, index, 30, r"\.start\(\)")


# ---------------------------------------------------------------------------
# Force unwraps: tell `foo!` apart from an implicitly unwrapped declaration
# ---------------------------------------------------------------------------

# A `!` that follows an identifier character, `)` or `]`, that is not part of
# `!=`/`!==`, and that is not the tail of `try!` or `as!` (their own rules).
FORCE_UNWRAP = re.compile(r"(?<=[\w\)\]])(?<!\btry)(?<!\bas)!(?!=)")

# A type annotated implicitly unwrapped: `: NSWindow!`, `: [Int]!`,
# `-> Foo!`, and a closure type `var handler: (() -> Void)!`.
_IUO_TYPE = r"(?:\[[^\]\n]*\]|[A-Z][\w.]*(?:<[^>\n]*>)?)"
_IUO_ANNOTATION = re.compile(r"(?::|->)\s*" + _IUO_TYPE + r"!(?!=)")
_IUO_CLOSURE = re.compile(r"\b(?:var|let)\s+\w+\s*:\s*\(.*\)!(?!=)")
# Only lines that declare something can contain an annotation.
_DECLARES = re.compile(r"\b(?:var|let|func|init|subscript)\b")


def iuo_bang_positions(line):
    """Indexes of the `!` characters on a (code-view) line that end an
    implicitly unwrapped type rather than force-unwrap a value."""
    if not _DECLARES.search(line):
        return set()
    positions = {m.end() - 1 for m in _IUO_ANNOTATION.finditer(line)}
    positions |= {m.end() - 1 for m in _IUO_CLOSURE.finditer(line)}
    return positions


def has_real_force_unwrap(lines, index):
    """True when the line has a force unwrap that is not an IUO declaration.
    (Used inversely: the force-unwrap rule's `unless`.)"""
    line = lines[index]
    iuo = iuo_bang_positions(line)
    return any(m.start() not in iuo for m in FORCE_UNWRAP.finditer(line))


# ---------------------------------------------------------------------------
# The rules (the names are part of the interface)
# ---------------------------------------------------------------------------

# A declaration of a variable or constant whose type is implicitly unwrapped.
_IUO_DECLARATION = (r"\b(?:var|let)\s+\w+\s*:\s*(?:" + _IUO_TYPE + r"!(?!=)|\(.*\)!(?!=))")

RULES = [
    # ---- ERROR: a certain trap or a broken rule -------------------------
    Rule("try-bang", ERROR, r"\btry!",
         "try! traps when the call throws; use try, XCTAssertNoThrow, or XCTUnwrap"),
    Rule("as-bang", ERROR, r"\bas!",
         "as! traps when the cast fails; use as? with XCTUnwrap or a guard"),
    Rule("crash-call", ERROR,
         r"(?<![\w.])(?<!func )(?<!case )(?:Darwin\.|Swift\.)?"
         r"(?:fatalError|preconditionFailure|precondition|assertionFailure|assert|exit|abort)\s*\(",
         "this call ends the test host; report a failure with XCTFail instead"),
    Rule("force-unwrap", ERROR, FORCE_UNWRAP.pattern,
         "a force unwrap traps on nil; use XCTUnwrap, guard, or optional chaining",
         # Excused only when every `!` on the line is an IUO type annotation.
         unless=lambda lines, i: not has_real_force_unwrap(lines, i)),
    Rule("unowned-capture", ERROR, r"\bunowned\b",
         "unowned traps when the object is already released; capture weak"),
    # Ways to find the REAL home directory.
    Rule("real-library", ERROR,
         r"\bNSHomeDirectory\s*\(|homeDirectoryForCurrentUser|\bgetpwuid\b|\"~/",
         "this reaches the user's live library; use the sandbox TextMouthRuntime provides",
         view="code_with_strings",
         # A path built under a temporary folder is not the user's.
         unless=lambda lines, i: re.search(
             r"temporaryDirectory|NSTemporaryDirectory", lines[i]) is not None),
    # The bare literal ".TextMouth" (a path component to append to some home).
    # One inside an absolute path ("/Users/reader/.TextMouth") is an inert fake
    # path in an assertion, so a preceding "/" excuses it; and a home made by a
    # sandbox helper within the 12 lines above is the test's own folder.
    Rule("real-library", ERROR, r"(?<![/\w])\.TextMouth\"",
         "the data folder's name appended to a home; make sure that home is a "
         "sandbox, never the user's real one",
         view="code_with_strings",
         unless=lambda lines, i: mentions_above(
             lines, i, 12, r"[Ss]andbox|makeMigrationBase|[tT]emporaryDirectory")),
    Rule("real-microphone", ERROR,
         r"(?<!\w)AVAudioRecorder\s*\(|AVCaptureDevice\.requestAccess|AVCaptureDevice\.default\(for:\s*\.audio",
         "a test must never record from a real microphone; use a fake recorder"),

    # ---- REVIEW: suspect; a person decides -------------------------------
    Rule("literal-subscript", REVIEW, r"[\w\)\]]\[\d+\]",
         "a literal subscript traps when out of range; check the count first "
         "(XCTAssertEqual(x.count, n), XCTUnwrap, or .first/.last)",
         unless=guarded_subscript),
    Rule("iuo-declaration", REVIEW, _IUO_DECLARATION,
         "an implicitly unwrapped optional traps when read while nil; "
         "prefer a plain optional or initialize it in setUp"),
    Rule("remove-first-last", REVIEW,
         r"\.(?:removeFirst|removeLast)\s*\(\s*\)|\.popLast\s*\(\s*\)\s*!",
         "removing from an empty collection traps; check isEmpty or count first",
         unless=guarded_removal),
    Rule("fulfill-without-guard", REVIEW, r"\.fulfill\s*\(\s*\)",
         "an expectation fulfilled twice aborts the host; set assertForOverFulfill = false "
         "or expectedFulfillmentCount where it is made",
         unless=guarded_fulfill),
    Rule("main-sync", REVIEW, r"\bDispatchQueue\.main\.sync\b",
         "DispatchQueue.main.sync deadlocks when already on the main thread"),
    Rule("blocking-wait", REVIEW, r"\.wait\s*\(\s*\)",
         "wait() with no timeout can hang the test host; pass a timeout"),
    Rule("real-sound", REVIEW,
         r"(?<!\w)NSSound\s*\(|(?<!\w)NSSound\.beep|(?<!\w)AVAudioPlayer\s*\(|"
         r"(?<!\w)AV(?:Queue)?Player\s*\(|(?i:synthesizer)\w*\.speak\s*\(",
         "a test must never play sound aloud; use a fake player or write(...) buffers"),
    Rule("real-sound", REVIEW, r"(?<!\w)AVAudioEngine\s*\(\s*\)",
         "an AVAudioEngine that is started plays sound aloud; use manual rendering or a fake",
         unless=engine_never_started),
]


# ---------------------------------------------------------------------------
# Self-test: one snippet that must hit and one that must not, per rule
# ---------------------------------------------------------------------------

# (rule name, snippet that must produce a hit, snippet that must not)
SELFTEST_CASES = [
    ("try-bang", "let d = try! Data(contentsOf: url)", 'let s = "try! is bad" // try! no'),
    ("as-bang", "let v = thing as! Widget", "let v = thing as? Widget"),
    ("crash-call", 'fatalError("boom")', 'let s = "fatalError(" // exit('),
    ("crash-call", "precondition(x > 0)", "XCTAssert(x > 0)"),
    ("crash-call", "assert(ready)", "process.exit(0)"),
    ("crash-call", "exit(1)", "func exit(_ code: Int) {}"),
    ("force-unwrap", "let n = list.first!.name", 'let s = "Finished!"'),
    ("force-unwrap", "let n = f()!", "if !list.isEmpty { }"),
    ("force-unwrap", "let w = dict[key]!", "if a != b { }"),
    ("force-unwrap", 'let t = "x \\(maybe!) y"', "// maybe!"),
    ("force-unwrap", "let s = try XCTUnwrap(x)!", "var window: NSWindow!"),
    ("force-unwrap", "foo(label: bar!)", "let r = try! f()"),
    ("unowned-capture", "{ [unowned self] in run() }", "{ [weak self] in run() } // unowned"),
    ("real-library", "let h = NSHomeDirectory()", "let h = NSTemporaryDirectory()"),
    ("real-library", 'let p = "~/Library/x"', 'let p = FileManager.default.temporaryDirectory'),
    ("real-library", 'let u = home.appendingPathComponent(".TextMouth")', '// the .TextMouth" folder'),
    ("real-library", "let h = FileManager.default.homeDirectoryForCurrentUser", "let h = home"),
    ("real-library", 'let u = home.appendingPathComponent(".TextMouth")',
     'let home = try makeSandboxDirectory("A")\nlet u = home.appendingPathComponent(".TextMouth")'),
    ("real-library", 'let u = home.appendingPathComponent(".TextMouth")', 'let u = URL(fileURLWithPath: "/Users/reader/.TextMouth")'),
    ("real-microphone", "let r = try AVAudioRecorder(url: u, settings: s)", "let r = FakeAVAudioRecorder(url: u)"),
    ("real-microphone", "AVCaptureDevice.requestAccess(for: .audio) { _ in }", "let device = FakeCaptureDevice()"),
    ("literal-subscript", "let a = items[0]", "let a = items.first"),
    ("literal-subscript", "let a = f(x)[1]", "let r: [Int] = [0]"),
    ("literal-subscript", "let a = rows[1]", "XCTAssertEqual(rows.count, 2)\n\nlet a = rows[1]"),
    ("literal-subscript", "let a = rows[1]", "guard !rows.isEmpty else { return }\nlet a = rows[0]"),
    ("iuo-declaration", "var window: NSWindow!", "var window: NSWindow?"),
    ("iuo-declaration", "private var items: [Item]!", 'let s = "var x: Foo!"'),
    ("iuo-declaration", "var handler: (() -> Void)!", "let x: Foo = make()"),
    ("remove-first-last", "let x = queue.removeFirst()", "let x = queue.dropFirst()"),
    ("remove-first-last", "stack.removeLast()", "guard !stack.isEmpty else { return }\nstack.removeLast()"),
    ("fulfill-without-guard", "done.fulfill()", "done.assertForOverFulfill = false\ndone.fulfill()"),
    ("fulfill-without-guard", "ready.fulfill()", "let e = expectation(description: \"x\")\ne.expectedFulfillmentCount = 2\ne.fulfill()"),
    ("main-sync", "DispatchQueue.main.sync { work() }", "DispatchQueue.main.async { work() }"),
    ("blocking-wait", "group.wait()", "group.wait(timeout: .now() + 1)"),
    ("real-sound", "NSSound.beep()", 'let n = FakeNSSound()'),
    ("real-sound", "let p = AVAudioPlayer(contentsOf: url)", "let p = FakeAVAudioPlayer()"),
    ("real-sound", "let p = AVPlayer(url: u)", "let p = AVPlayerItem(url: u)"),
    ("real-sound", "synthesizer.speak(utterance)", "fakeEngine.speak(utterance)"),
    ("real-sound", "let e = AVAudioEngine()\ntry e.start()", "let e = AVAudioEngine()\nlet n = e.mainMixerNode"),
    ("real-sound", "let e = AVAudioEngine()\ntry e.start()",
     "let e = AVAudioEngine()\ntry e.enableManualRenderingMode(.offline, format: f, maximumFrameCount: 512)\ntry e.start()"),
]


def selftest():
    """Run every canned case; print failures; return True when all pass."""
    failures = []

    def rules_hit(snippet):
        hits = difflint.lint_file("snippet.swift", snippet, RULES)
        return {h.rule for h in hits if not h.suppressed}

    for rule, must_hit, must_not in SELFTEST_CASES:
        if rule not in rules_hit(must_hit):
            failures.append(f"{rule} should hit: {must_hit!r}")
        if must_not is not None and rule in rules_hit(must_not):
            failures.append(f"{rule} should not hit: {must_not!r}")

    # Every rule has at least one case.
    covered = {case[0] for case in SELFTEST_CASES}
    for rule in RULES:
        if rule.name not in covered:
            failures.append(f"{rule.name} has no selftest case")

    # lint-ok suppresses, is counted, and needs a reason.
    hits = difflint.lint_file("s.swift", "let a = x! // lint-ok: x is set two lines up", RULES)
    if not (len(hits) == 1 and hits[0].suppressed):
        failures.append("lint-ok with a reason should suppress")
    hits = difflint.lint_file("s.swift", "let a = x! // lint-ok:", RULES)
    if not (len(hits) == 1 and not hits[0].suppressed):
        failures.append("lint-ok without a reason must not suppress")

    # A multi-line string and a block comment hide their contents.
    hits = difflint.lint_file("s.swift", 'let s = """\n  try! x!\n"""\n/* y! */\nlet ok = 1', RULES)
    if hits:
        failures.append(f"multi-line string or block comment should hide hits: {hits}")

    # only_lines limits the check to the added lines.
    hits = difflint.lint_file("s.swift", "let a = x!\nlet b = y!", RULES, only_lines={2})
    if [h.line for h in hits] != [2]:
        failures.append("only_lines should limit the check")

    for failure in failures:
        print(f"selftest FAILED: {failure}")
    if not failures:
        print(f"trap-lint selftest: all {len(SELFTEST_CASES)} rule cases passed")
    return not failures


if __name__ == "__main__":
    sys.exit(difflint.main(
        RULES, DEFAULT_PATHS, sys.argv[1:], selftest=selftest,
        description="Find test code a branch adds that can trap, play sound, "
                    "record, or touch the user's real library."))
