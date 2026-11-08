#!/usr/bin/env python3
"""markup-stack-proof.py: proves, in child processes with limits, that MarkupGuard's parse cannot overflow a stack.

MarkupGuard runs SwiftSoup's parse, the depth check after it, and the release of
a refused tree on a thread whose stack holds the deepest tree the memory limit
allows (MarkupGuard.onLargeStack). This script compiles two small programs
against the committed MarkupGuard sources and the SwiftSoup the main checkout's
last build left in build/DerivedData, in a debug and a Release build, and runs
them. Nothing here runs in the test host, because a stack overflow ends the
process that has it.

  measure/main.swift  parses a deeply nested document on a thread with a 4 GiB
                      stack and counts the stack pages it touched with mincore:
                      how many bytes a level of the tree costs SwiftSoup's parse,
                      and its release.
  proof/main.swift    calls MarkupGuard from a thread with a 512 KiB stack (an
                      import's) with the first layer's depth limit lifted and the
                      second layer's at 128; the document must be refused with
                      the depth sentence. Its "raw" mode calls SwiftSoup alone
                      from the same thread, to show the shapes that overflow
                      without the big stack.

Usage:
  markup-stack-proof.py build [--debug|--release|--both]
  markup-stack-proof.py measure --release|--debug [N]   per-level stack cost, every shape
  markup-stack-proof.py proof   --release|--debug       the proof cases, each in a child with a CPU and a wall limit

Every build and run takes the Mac's heavy-work lock (Scripts/agents/heavy_lock.py).
Output goes to build/markup-stack/ in the main checkout (overwritten each run).
Run with python3 -I -B.
"""
import os
import resource
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
# The main checkout holds the build products (SwiftSoup's objects) and the lock.
MAIN = Path("/Users/roberteggleston/programming/ai/claude/swift/TextMouth")
PRODUCTS = MAIN / "build" / "DerivedData" / "Build" / "Products"
OUT = MAIN / "build" / "markup-stack"
GUARD_SOURCES = [REPO / "TextMouth" / "Parsers" / name for name in ("MarkupGuard.swift", "MarkupScanner.swift", "MarkupNesting.swift")]

sys.path.insert(0, str(REPO / "Scripts" / "agents"))
import heavy_lock  # noqa: E402  (imported by path, after sys.path is set)

# The proof cases: mode, shape, N, dialect. HTML grows with the square of the
# depth once the first layer's count is lifted (it is not, in the app), so the
# HTML cases stop at 50,000 levels; XML is linear and goes to the memory limit.
PROOF_CASES = (
    [("guard", shape, n, "html") for shape in ("div", "list", "quote") for n in (5_000, 50_000)]
    + [("guard", shape, 5_000, "html") for shape in ("divclose", "listclose", "quoteclose", "spanclose")]
    + [("guard", shape, n, "xml") for shape in ("div", "list", "quote") for n in (5_000, 50_000)]
    + [("guard", "div", 990_000, "xml"), ("guard", "list", 490_000, "xml"), ("guard", "quote", 990_000, "xml"), ("guard", "spanclose", 990_000, "xml")]
    # Without the big stack, the deepest shapes overflow a 512 KiB stack.
    + [("raw", "listclose", 3_000, "html"), ("raw", "spanclose", 5_000, "html")]
    # A tree that passes both layers is returned.
    + [("ok", "div", 50, "html")]
)
MEASURE_SHAPES = ("div", "span", "ul", "blockquote", "divclose", "spanclose", "attr", "attrclose", "ol", "bq", "a", "table")


def build(program, release):
    """Compiles the program (`proof` or `measure`) into OUT, a debug or Release build."""
    OUT.mkdir(parents=True, exist_ok=True)
    products = PRODUCTS / ("Release" if release else "Debug")
    name = "%s-%s" % (program, "release" if release else "debug")
    command = ["swiftc", "-swift-version", "5", "-I", str(products), "-module-cache-path", str(OUT / "modcache"), "-suppress-warnings",
               "-o", str(OUT / name)]
    if release:
        command += ["-O", "-whole-module-optimization"]
    else:
        # The Debug products were built with coverage on, so their objects need the profile runtime to link.
        command += ["-Onone", "-profile-generate", "-profile-coverage-mapping"]
    command += [str(HERE / "markup-stack-proof" / program / "main.swift")] + [str(path) for path in GUARD_SOURCES] + [str(products / "SwiftSoup.o")]
    done = subprocess.run(command, capture_output=True, text=True)
    if done.returncode != 0:
        print("\n".join(line for line in (done.stdout + done.stderr).splitlines() if "error" in line)[:4000])
        sys.exit(1)
    return OUT / name


def run_child(binary, arguments, wall_seconds):
    """Runs one child with a CPU limit and a wall-clock limit; returns how it ended, its seconds, its peak memory in MB, and its last line."""
    sink_path = OUT / "child.out"

    def limits():
        """Applied in the child before it runs: a CPU limit, and no core dump."""
        resource.setrlimit(resource.RLIMIT_CPU, (int(wall_seconds), int(wall_seconds)))
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

    start = time.time()
    with open(sink_path, "w") as sink:
        child = subprocess.Popen([str(binary)] + [str(a) for a in arguments], stdout=sink, stderr=sink, preexec_fn=limits,
                                 env=dict(os.environ, LLVM_PROFILE_FILE=str(OUT / "coverage.profraw")))
    timed_out = False
    while True:
        pid, status, usage = os.wait4(child.pid, os.WNOHANG)
        if pid:
            break
        if time.time() - start > wall_seconds:
            child.kill()
            timed_out = True
            pid, status, usage = os.wait4(child.pid, 0)
            break
        time.sleep(0.2)
    if timed_out:
        ended = "TIMED OUT"
    elif os.WIFSIGNALED(status):
        ended = "SIGNAL " + signal.Signals(os.WTERMSIG(status)).name
    else:
        ended = "exit %d" % os.WEXITSTATUS(status)
    lines = sink_path.read_text(errors="replace").strip().splitlines()
    return ended, time.time() - start, usage.ru_maxrss // (1 << 20), lines[-1] if lines else ""


def main():
    """Runs the command named on the command line, under the heavy lock."""
    args = sys.argv[1:]
    if not args or args[0] not in ("build", "measure", "proof"):
        print(__doc__)
        return 2
    command = args[0]
    release = "--debug" not in args
    with heavy_lock.held("markup-stack-" + command, 3 * 60 * 60) as taken:
        if not taken:
            print("markup-stack-proof: the heavy lock stayed busy", file=sys.stderr)
            return 3
        if command == "build":
            for flavour in ((False, True) if "--both" in args else (release,)):
                for program in ("proof", "measure"):
                    print("built", build(program, flavour))
            return 0
        if command == "measure":
            binary = build("measure", release)
            n = next((a for a in args[1:] if a.isdigit()), "8000")
            for shape in MEASURE_SHAPES:
                ended, _, _, line = run_child(binary, [shape, n], 600)
                print("[%s] %s" % (ended, line), flush=True)
            return 0
        binary = build("proof", release)
        failures = 0
        for mode, shape, n, dialect in PROOF_CASES:
            ended, seconds, peak, line = run_child(binary, [mode, shape, n, dialect], 600)
            # A guard case must end normally and say the second layer refused the tree; a raw case must overflow.
            good = (ended == "exit 0" and ("refused by the second layer" in line or mode == "ok")) if mode != "raw" else ended.startswith("SIGNAL")
            failures += 0 if good else 1
            print("%s [%s] %s %s %s %s | %.1f s, peak %d MB | %s" % ("ok  " if good else "FAIL", ended, mode, shape, n, dialect, seconds, peak, line), flush=True)
        print("%d of %d cases failed" % (failures, len(PROOF_CASES)))
        return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
