#!/usr/bin/env python3
"""run.py: compares the released SwiftSoup with Vendor/SwiftSoup over a large corpus.

Usage: python3 -I Scripts/agents/run_locked.py NAME python3 -I Scripts/test/swiftsoup-corpus/run.py [options]

Run it through the heavy-work lock (it compiles twice and parses tens of
thousands of documents), when SwiftSoup is upgraded or make_vendor.py changes.
SwiftSoupCorpusTests is the small, hosted version of the same check, which
runs on GitHub with every train; this is the large one, in Release builds.

What it does:
  1. Gathers the corpus: every markup document under TestData (loose .html,
     .htm, .xhtml, .xml, .ncx, .opf, and .smil files, and those members of
     every ZIP container: EPUBs, DAISY books, DOCX, ODT), numbered in the order
     of their paths, into WORK/corpus.
  2. Builds two programs from main.swift and TextMouthProductionTests/
     SwiftSoupCorpusKit.swift, one linked with the released SwiftSoup (compiled
     file by file at -Osize, as Xcode compiles a package) and one with
     Vendor/SwiftSoup (compiled as one module at -Osize, as project.yml does).
  3. Runs both over the corpus: each document parsed three ways (the HTML
     parser, the XML parser, a body fragment), and each document of at most
     300,000 bytes also as DAMAGED damaged copies (a range deleted, repeated,
     or troublesome markup inserted, by a generator seeded from its name).
  4. Compares the two outputs line by line, prints the counts, the first
     differing documents, and a verdict.

Options:
  --upstream DIR   the SwiftSoup release checkout (default: the one Xcode
                   resolved in the main checkout's build/DerivedData)
  --vendored DIR   the copy (default: Vendor/SwiftSoup of this checkout)
  --testdata DIR   the documents (default: the main checkout's TestData, which
                   holds more than a clean checkout's)
  --work DIR       scratch folder (default: build/swiftsoup-corpus of the main
                   checkout); files in it are overwritten, none deleted
  --damaged N      damaged copies of each document (default 20)
  --timing-runs N  parses timed for the speed lines (default 31)

Exit status: 0 when every parse is identical, 1 when any differs, 2 for a
problem building or running.
"""
import argparse
import subprocess
import sys
import time
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parent.parent.parent

# repo_paths.py is in Scripts/agents; python3 -I leaves its folder out of sys.path.
sys.path.insert(0, str(REPOSITORY / "Scripts" / "agents"))
import repo_paths  # noqa: E402  (imported by path, after sys.path is set)

# The main checkout, which holds the package checkout Xcode made and the test data, whichever worktree runs this.
MAIN_CHECKOUT = repo_paths.main_checkout()
KIT = REPOSITORY / "TextMouthProductionTests" / "SwiftSoupCorpusKit.swift"
DRIVER = HERE / "main.swift"
MARKUP = {".html", ".htm", ".xhtml", ".xml", ".ncx", ".opf", ".smil"}
LARGEST_DOCUMENT = 8 * 1024 * 1024

# What Xcode passes for a package target in a Release build, less its plumbing:
# the module's language mode, the platform it targets, and exclusivity checks.
MODULE_FLAGS = ["-enforce-exclusivity=checked", "-swift-version", "6", "-target", "arm64-apple-macos14.0",
                "-DSWIFT_PACKAGE", "-suppress-warnings", "-parse-as-library", "-module-name", "SwiftSoup", "-Osize"]


def gather(testdata, folder):
    """Writes every markup document of `testdata` into `folder`, numbered in
    path order, with its source in index.tsv; returns how many and how many bytes."""
    folder.mkdir(parents=True, exist_ok=True)
    rows = []

    def keep(data, source, extension):
        """Writes one document under the next number."""
        name = f"{len(rows):04d}{extension}"
        (folder / name).write_bytes(data)
        rows.append((name, len(data), source))

    for path in sorted(testdata.rglob("*"), key=lambda p: str(p).encode("utf-8")):
        if not path.is_file():
            continue
        relative = path.relative_to(testdata)
        extension = path.suffix.lower()
        if extension in MARKUP and path.stat().st_size <= LARGEST_DOCUMENT:
            keep(path.read_bytes(), str(relative), extension)
        elif zipfile.is_zipfile(path):
            try:
                with zipfile.ZipFile(path) as archive:
                    for info in archive.infolist():
                        member = Path(info.filename).suffix.lower()
                        if member in MARKUP and info.file_size <= LARGEST_DOCUMENT:
                            keep(archive.read(info), f"{relative}!{info.filename}", member)
            except (zipfile.BadZipFile, NotImplementedError, RuntimeError, OSError):
                continue
    (folder / "index.tsv").write_text("".join(f"{n}\t{b}\t{s}\n" for n, b, s in rows), encoding="utf-8")
    return len(rows), sum(row[1] for row in rows)


def build(name, sources, wmo, work):
    """Compiles `sources` as the module SwiftSoup (whole, or file by file),
    then the driver and the kit against it; returns the program's path."""
    folder = work / name
    folder.mkdir(parents=True, exist_ok=True)
    compile_command = ["xcrun", "swiftc", "-c", *MODULE_FLAGS, "-j4", "-emit-module",
                       "-emit-module-path", str(folder / "SwiftSoup.swiftmodule"), *map(str, sources)]
    if wmo:
        compile_command += ["-wmo", "-o", str(folder / "SwiftSoup.o")]
    done = subprocess.run(compile_command, cwd=folder, capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise SystemExit(f"compiling {name} failed:\n{done.stderr[-4000:]}")
    program = folder / "soupcorpus"
    link = subprocess.run(
        ["xcrun", "swiftc", "-Osize", "-swift-version", "5", "-target", "arm64-apple-macos14.0",
         "-I", str(folder), str(DRIVER), str(KIT), *sorted(str(p) for p in folder.glob("*.o")),
         "-o", str(program)],
        cwd=folder, capture_output=True, text=True, check=False)
    if link.returncode != 0:
        raise SystemExit(f"linking {name} failed:\n{link.stderr[-4000:]}")
    return program


def run_program(program, corpus, damaged, output):
    """Runs `program` over the corpus, its lines going to `output`; returns the seconds taken."""
    start = time.monotonic()
    with open(output, "w", encoding="utf-8") as handle:
        done = subprocess.run([str(program), str(corpus), str(damaged)], stdout=handle, stderr=subprocess.PIPE,
                              text=True, check=False)
    if done.returncode != 0:
        raise SystemExit(f"{program.parent.name} stopped with status {done.returncode}:\n{done.stderr[-2000:]}")
    return time.monotonic() - start


def time_parses(upstream, vendored, corpus, runs):
    """Prints the median time of the HTML parser on the largest .html
    document of the corpus and of the XML parser on its largest .xml one, for
    the release and for the copy (the harness of the November 14, 2026
    research: frankenstein.html and the DTBook of hyperion_daisy.zip)."""
    rows = [line.split("\t") for line in (corpus / "index.tsv").read_text(encoding="utf-8").splitlines()]
    for mode, extension in (("html", ".html"), ("xml", ".xml")):
        candidates = [row for row in rows if row[0].endswith(extension)]
        if not candidates:
            continue
        largest = max(candidates, key=lambda row: int(row[1]))
        for name, program in (("upstream", upstream), ("vendored", vendored)):
            done = subprocess.run([str(program), "--time", str(corpus / largest[0]), mode, str(runs)],
                                  capture_output=True, text=True, check=False)
            print(f"timing {name}: {done.stdout.strip()} ({largest[2]})")


def compare(left, right, index):
    """Compares two output files line by line; returns (lines, differing lines,
    the first few differing names with the parse that differs)."""
    names = {}
    for line in index.read_text(encoding="utf-8").splitlines():
        number, _size, source = line.split("\t", 2)
        names[number] = source
    differing = []
    count = 0
    with open(left, encoding="utf-8") as a, open(right, encoding="utf-8") as b:
        for first, second in zip(a, b):
            count += 1
            if first != second:
                key, *one = first.rstrip("\n").split("\t")
                _key, *two = second.rstrip("\n").split("\t")
                parses = [("html", "xml", "fragment")[i] for i in range(3) if one[i] != two[i]]
                differing.append(f"{key} ({names.get(key.split('#')[0].split('.')[0], '?')}): {', '.join(parses)}")
    with open(left, encoding="utf-8") as a, open(right, encoding="utf-8") as b:
        lengths = (sum(1 for _ in a), sum(1 for _ in b))
    return count, differing, lengths


def main(argv=None):
    """Builds, runs, and compares; returns the exit status."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--upstream", type=Path,
                        default=MAIN_CHECKOUT / "build/DerivedData/SourcePackages/checkouts/SwiftSoup")
    parser.add_argument("--vendored", type=Path, default=REPOSITORY / "Vendor" / "SwiftSoup")
    parser.add_argument("--testdata", type=Path, default=MAIN_CHECKOUT / "TestData")
    parser.add_argument("--work", type=Path, default=MAIN_CHECKOUT / "build" / "swiftsoup-corpus")
    parser.add_argument("--damaged", type=int, default=20)
    parser.add_argument("--timing-runs", type=int, default=31, help="parses timed for each parser (default 31)")
    options = parser.parse_args(argv)

    for needed in (options.upstream / "Sources", options.vendored / "Sources", options.testdata, KIT, DRIVER):
        if not needed.exists():
            print(f"missing: {needed}", file=sys.stderr)
            return 2
    options.work.mkdir(parents=True, exist_ok=True)
    corpus = options.work / "corpus"
    documents, size = gather(options.testdata, corpus)
    print(f"corpus: {documents} documents, {size} bytes, from {options.testdata}")

    upstream = build("upstream", sorted((options.upstream / "Sources").glob("*.swift")), False, options.work)
    vendored = build("vendored", sorted((options.vendored / "Sources").glob("*.swift")), True, options.work)
    seconds_upstream = run_program(upstream, corpus, options.damaged, options.work / "upstream.out")
    seconds_vendored = run_program(vendored, corpus, options.damaged, options.work / "vendored.out")

    time_parses(upstream, vendored, corpus, options.timing_runs)
    lines, differing, lengths = compare(options.work / "upstream.out", options.work / "vendored.out", corpus / "index.tsv")
    print(f"inputs: {lines} ({documents} documents and {lines - documents} damaged copies), parses: {lines * 3}")
    print(f"time: upstream {seconds_upstream:.1f} s, vendored {seconds_vendored:.1f} s")
    if lengths[0] != lengths[1]:
        print(f"FAILED: the outputs have {lengths[0]} and {lengths[1]} lines")
        return 1
    if differing:
        print(f"FAILED: {len(differing)} inputs read differently; the first ones:")
        for entry in differing[:30]:
            print(f"  {entry}")
        return 1
    print(f"PASSED: all {lines * 3} parses are identical")
    return 0


if __name__ == "__main__":
    sys.exit(main())
