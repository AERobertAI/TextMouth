#!/usr/bin/env python3
"""app-size.py: measures a built app bundle's size, and builds the iPhone app's Release build to measure.

The user's limits, for the Mac app and the iPhone app alike (the two are kept at parity): 30 MB is the real limit
and 40 MB the strict one. `make check` measures the Mac app with `app_size` in Scripts/check.sh: the sum of the
sizes of the regular files in the bundle, in decimal megabytes (1 MB = 1,000,000 bytes). This tool measures the same
way, for a Mac or an iPhone app, and adds what only the iPhone app has:

  (a) the app           the sum of the regular files' sizes, as check.sh's `app_size` adds them up
  (b) the IPA           the app zipped under Payload/, as an .ipa is (needs --ipa, or the build subcommand)
  (c) the download      an estimate of the App Store download: the IPA with each Mach-O file counted at its full
                        size, since the App Store encrypts executables and encrypted bytes do not compress
  (d) the biggest files the largest regular files in the bundle, and (with a link map) each linked library's
                        share of the executable

Usage (Python 3 standard library only; run from anywhere):
    python3 -I -B Scripts/ios/app-size.py measure APP [--ipa] [--ipa-out FILE] [--link-map FILE] [--top N] [--json]
    python3 -I -B Scripts/ios/app-size.py build [--derived-data DIR] [--limit-minutes N] [--json]
    python3 -I -B Scripts/ios/app-size.py --selftest

`build` runs an unsigned Release build of the target TextMouthiOS for the iphoneos SDK (the arm64 device) into
DERIVED_DATA, then measures the app with the IPA and the link map. It does not take the heavy-work lock itself: on
this Mac `make ios-size` runs it through Scripts/agents/run_locked.py, and on a GitHub runner there is no lock.
Exit status: 0 measured (even over the limits: the report says so), 1 the build failed or no app was found, 2 a bad
command line, 3 with --check and the app larger than the strict limit (40 MB; between 30 and 40 MB it says so and exits 0).
"""
import argparse
import contextlib
import glob
import io
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

# Importing this module must leave no __pycache__ folder in the repository.
sys.dont_write_bytecode = True

# The repository's root: this file is in Scripts/ios.
ROOT = Path(__file__).resolve().parents[2]
# The target, product names, and Release build settings (the size settings among them, defined once in
# Scripts/size_settings.py) that this tool shares with Scripts/ios/install-on-device.py: Scripts/ios/iphone_release.py,
# which needs Scripts/ on the path too.
sys.path.insert(0, str(ROOT / "Scripts"))
sys.path.insert(0, str(ROOT / "Scripts" / "ios"))
import iphone_release  # noqa: E402

# One megabyte, as Scripts/check.sh counts it.
MEGABYTE = 1_000_000


def limits_from_gate(text):
    """The two limits, in megabytes, that the text of Scripts/check.sh defines once for the Mac's gate and this tool's:
    (APP_SIZE_WARNING_MB, APP_SIZE_LIMIT_MB). Raises ValueError when either is missing."""
    found = [re.search(rf"^readonly {name}=(\d+)$", text, re.MULTILINE) for name in ("APP_SIZE_WARNING_MB", "APP_SIZE_LIMIT_MB")]
    if not all(found):
        raise ValueError("Scripts/check.sh does not define APP_SIZE_WARNING_MB and APP_SIZE_LIMIT_MB")
    return int(found[0].group(1)), int(found[1].group(1))


# The user's limits, in megabytes: the real one, and the strict one. Read from check.sh, their one definition, so the
# Mac's app and the iPhone's cannot drift apart.
LIMIT_MB, STRICT_LIMIT_MB = limits_from_gate((ROOT / "Scripts" / "check.sh").read_text())
# Where the device build keeps its derived data unless --derived-data says otherwise: an absolute folder, and the one
# definition of it (`make ios-size` and `make check` pass none), since xcodebuild resolves a relative path against its own
# folders, not this tool's (board finding 6513).
DEFAULT_DERIVED_DATA = ROOT / "build" / "ios-size-DerivedData"
# How many of the biggest files the report lists.
DEFAULT_TOP = 15
# The target and SDK of the device build. It names the target and the SDK, not the scheme and a destination: a scheme
# needs a destination, and `-destination generic/platform=iOS` needs the iOS platform installed, which a Mac with only
# Xcode's SDKs, like the one the agents use, lacks. The target is the one the scheme TextMouthiOS builds. A target build
# takes no -derivedDataPath, so the folders a derived-data folder holds are named one by one, in the same layout (products
# in Build/Products/Release-iphoneos, objects and the link map in Build/Intermediates.noindex, and the module cache in
# ModuleCache.noindex, where a runner's stale-cache check (Scripts/agents/runner_module_cache.py) looks). The folder name Xcode gives its products. The product's name is
# TextMouth, as project.yml sets it (the Mac app has the same name).
TARGET = iphone_release.TARGET
SDK = iphone_release.SDK
PRODUCTS_FOLDER = iphone_release.PRODUCTS_FOLDER
APP_NAME = iphone_release.APP_NAME
# The longest a build may take, in minutes, unless --limit-minutes says otherwise.
DEFAULT_BUILD_LIMIT_MINUTES = 40
# The first four bytes of a Mach-O file (thin, 32 and 64 bit, in either byte order), and of a universal ("fat") one.
THIN_MACHO_MAGICS = {b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe"}
FAT_MACHO_MAGIC = b"\xca\xfe\xba\xbe"
# A universal file has at most a handful of architectures; a Java class file also starts with 0xCAFEBABE, and its
# next four bytes (the version) are far larger than this.
MAX_FAT_ARCHITECTURES = 16


def megabytes(byte_count):
    """`byte_count` in decimal megabytes, as the text "12.3" (to a tenth, as check.sh prints it)."""
    return f"{byte_count / MEGABYTE:.1f}"


def describe(byte_count):
    """A size as "12.3 MB (12,345,678 bytes)": the bytes settle a size that rounds to a limit itself."""
    return f"{megabytes(byte_count)} MB ({byte_count:,} bytes)"


def is_macho(path):
    """True when the file at `path` starts like a Mach-O executable, library, or universal binary. An unreadable file
    is not one."""
    try:
        with open(path, "rb") as handle:
            head = handle.read(8)
    except OSError:
        return False
    if head[:4] in THIN_MACHO_MAGICS:
        return True
    return head[:4] == FAT_MACHO_MAGIC and len(head) == 8 and 1 <= int.from_bytes(head[4:], "big") <= MAX_FAT_ARCHITECTURES


def regular_files(app):
    """Every regular file in the bundle at `app`, as (path relative to the bundle, size in bytes), sorted by path.
    A symbolic link is not a regular file and a link to a folder is not followed, exactly as `find -type f` in
    check.sh's `app_size` treats them, so the totals agree."""
    app = Path(app)
    found = []
    for folder, _, names in os.walk(app, followlinks=False):
        for name in names:
            path = Path(folder) / name
            info = os.lstat(path)
            if stat.S_ISREG(info.st_mode):
                found.append((str(path.relative_to(app)), info.st_size))
    return sorted(found)


def make_ipa(app, files, destination):
    """Zips the bundle at `app` as an .ipa is: every regular file of `files` under Payload/<the bundle's name>/, deflated.
    `destination` is a path to write the .ipa to, or a seekable binary stream. Returns the per-file sizes as a list of
    (archive name, compressed size, uncompressed size, whether it is a Mach-O file), in the archive's order, and the
    archive's size in bytes."""
    app = Path(app)
    entries = []
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for relative, _ in files:
            name = f"Payload/{app.name}/{relative}"
            archive.write(app / relative, name)
            info = archive.getinfo(name)
            entries.append((name, info.compress_size, info.file_size, is_macho(app / relative)))
        # The central directory is written when the archive closes; its size is counted from the file afterwards.
    if isinstance(destination, (str, os.PathLike)):
        size = os.path.getsize(destination)
    else:
        size = destination.getbuffer().nbytes
    return entries, size


def store_estimate(ipa_bytes, entries):
    """The estimated App Store download: the IPA with each Mach-O file counted at its full size instead of its deflated
    size, because the App Store encrypts executables and encrypted bytes do not compress."""
    deflated = sum(compressed for _, compressed, _, macho in entries if macho)
    full = sum(size for _, _, size, macho in entries if macho)
    return ipa_bytes - deflated + full


# A link map's list of object files: "[  3] /path/to/libFoo.a(bar.o)".
OBJECT_LINE = re.compile(r"^\[\s*(\d+)\]\s+(.*)$")
# A link map's symbol: "0x100004000<TAB>0x00000010<TAB>[  3] _name".
SYMBOL_LINE = re.compile(r"^0x[0-9A-Fa-f]+\s+0x([0-9A-Fa-f]+)\s+\[\s*(\d+)\]")


def library_of(object_path):
    """The name of what an object file of the link map belongs to: the static library for `libFoo.a(bar.o)`, the target
    for an object of Xcode's `Foo.build` folder, the framework or dylib for a linked binary, or the folder's name."""
    archive = re.match(r"^(.*\.a)\(.*\)$", object_path)
    if archive:
        return os.path.basename(archive.group(1))
    if object_path == "linker synthesized":
        return object_path
    # A Swift package's product is one merged object in the products folder ("Products/Release-iphoneos/cmark-gfm.o").
    product = re.search(r"/Products/[^/]+/([^/]+)\.o$", object_path)
    if product:
        return product.group(1)
    # Xcode nests the target's folder inside the project's ("TextMouth.build/Release-iphoneos/Foo.build/..."), so the
    # innermost one names the target.
    targets = re.findall(r"/([^/]+)\.build/", object_path)
    if targets:
        return targets[-1]
    base = os.path.basename(object_path)
    if base.endswith((".dylib", ".tbd")) or ".framework/" in object_path:
        return base
    return os.path.basename(os.path.dirname(object_path)) or base


def parse_link_map(text):
    """The bytes each library contributes to the executable, from a linker's map (`-Xlinker -map`, or Xcode's
    LD_GENERATE_MAP_FILE): a list of (library, bytes), the biggest first. It adds up the sizes of the symbols the
    link kept, so the symbols dead-stripped (listed after "# Dead Stripped Symbols") are not counted."""
    objects = {}
    totals = {}
    section = None
    for line in text.splitlines():
        if line.startswith("#"):
            if line.startswith("# Object files"):
                section = "objects"
            elif line.startswith("# Symbols"):
                section = "symbols"
            elif line.startswith("# Dead Stripped"):
                break
            elif line.startswith("# Sections"):
                section = "sections"
            continue
        if section == "objects":
            match = OBJECT_LINE.match(line)
            if match:
                objects[int(match.group(1))] = library_of(match.group(2).strip())
        elif section == "symbols":
            match = SYMBOL_LINE.match(line)
            if match:
                library = objects.get(int(match.group(2)), "unknown")
                totals[library] = totals.get(library, 0) + int(match.group(1), 16)
    return sorted(totals.items(), key=lambda item: (-item[1], item[0]))


def measure_app(app, want_ipa=False, ipa_out=None, link_map=None, top=DEFAULT_TOP):
    """Measures the bundle at `app` and returns a dict with its numbers: `app_bytes`, `file_count`, `top_files` (path
    and bytes of the biggest `top`), and, when `want_ipa` is true or `ipa_out` is given, `ipa_bytes` and
    `store_bytes`; with `link_map` (a path), `libraries`, a list of (library, bytes), and `executable_bytes`. With
    `ipa_out` the .ipa is kept at that path; otherwise it is built in memory and dropped."""
    files = regular_files(app)
    result = {
        "app": str(app),
        "app_bytes": sum(size for _, size in files),
        "file_count": len(files),
        "top_files": sorted(files, key=lambda item: (-item[1], item[0]))[:top],
    }
    if want_ipa or ipa_out:
        entries, ipa_bytes = make_ipa(app, files, str(ipa_out) if ipa_out else io.BytesIO())
        result["ipa_bytes"] = ipa_bytes
        result["store_bytes"] = store_estimate(ipa_bytes, entries)
        result["macho_bytes"] = sum(size for _, _, size, macho in entries if macho)
    if link_map:
        result["libraries"] = parse_link_map(Path(link_map).read_text(errors="replace"))
        result["executable_bytes"] = next((size for relative, size in files if relative == Path(app).stem), None)
    return result


def verdict(byte_count):
    """How a size stands against the limits, in a few words."""
    if byte_count > STRICT_LIMIT_MB * MEGABYTE:
        return f"over the strict {STRICT_LIMIT_MB} MB limit"
    if byte_count > LIMIT_MB * MEGABYTE:
        return f"over the {LIMIT_MB} MB limit, within the strict {STRICT_LIMIT_MB} MB"
    return f"within the {LIMIT_MB} MB limit"


def format_report(result, label="App"):
    """The measurement as lines of text, each a whole sentence a reader hears on its own (no table needed). `label`
    names the app, such as "iPhone app"."""
    lines = [f"{label}: {describe(result['app_bytes'])} in {result['file_count']} files, {verdict(result['app_bytes'])}."]
    if "ipa_bytes" in result:
        lines.append(f"{label} IPA: {describe(result['ipa_bytes'])}.")
        lines.append(f"{label} App Store download, estimated (Mach-O files at full size): {describe(result['store_bytes'])}, "
                     f"{verdict(result['store_bytes'])}.")
    for path, size in result["top_files"]:
        lines.append(f"  {describe(size)}  {path}")
    if "libraries" in result:
        total = sum(size for _, size in result["libraries"]) or 1
        lines.append(f"Executable by library (kept symbols, {describe(total)} of the "
                     f"{describe(result['executable_bytes']) if result.get('executable_bytes') else 'executable'}):")
        for library, size in result["libraries"][:DEFAULT_TOP]:
            lines.append(f"  {size / total * 100:.1f}%  {describe(size)}  {library}")
    return lines


# What a line of a run's ios-summary.txt starts with when it carries the size: the three headline lines (the app, the IPA,
# the download) first, then the detail lines (the biggest files, the libraries). Scripts/agents/merge_ios_shards.py
# reads these two prefixes back, for the train's and the suite's reports.
SUMMARY_PREFIX = "Size: "
SUMMARY_DETAIL_PREFIX = "Size detail: "


def summary_lines(result, label="iPhone app"):
    """The measurement as the lines a run's ios-summary.txt carries: the headlines (what format_report says first),
    each starting SUMMARY_PREFIX, then each file and library line starting SUMMARY_DETAIL_PREFIX."""
    lines = format_report(result, label)
    headlines = 3 if "ipa_bytes" in result else 1
    return ([SUMMARY_PREFIX + line for line in lines[:headlines]]
            + [SUMMARY_DETAIL_PREFIX + line.strip() for line in lines[headlines:]])


def find_link_map(derived_data):
    """The link map of the device build in `derived_data`, or None when Xcode wrote none."""
    pattern = f"{derived_data}/Build/Intermediates.noindex/*/{PRODUCTS_FOLDER}/{TARGET}.build/*LinkMap-normal-arm64.txt"
    found = sorted(glob.glob(pattern))
    return found[0] if found else None


def build_command(derived_data):
    """The argv of the device build: Release of the target TextMouthiOS for the iphoneos SDK, arm64, unsigned, small code
    (-Osize and the size settings of Scripts/size_settings.py's profile "auto": every one on GitHub Actions, only the light ones on a Mac, as the Makefile's development builds take them), no coverage, a link map, and the strip an archive does
    (DEPLOYMENT_POSTPROCESSING=YES: a plain build leaves the symbol table in the executable, 14.1 MB of the iPhone app's
    27.5 MB on November 16, 2026, and the App Store's app is archived; the target's own STRIP_INSTALLED_PRODUCT=YES and
    STRIP_STYLE=all then apply, and the Mac app's Release settings in project.yml say the same)."""
    return ["xcodebuild", "build", "-project", "TextMouth.xcodeproj", "-target", TARGET, "-configuration", "Release",
            "-sdk", SDK, "-clonedSourcePackagesDirPath", f"{derived_data}/SourcePackages",
            f"SYMROOT={derived_data}/Build/Products", f"OBJROOT={derived_data}/Build/Intermediates.noindex",
            f"MODULE_CACHE_DIR={derived_data}/ModuleCache.noindex", *iphone_release.release_settings(),
            "CODE_SIGNING_ALLOWED=NO", "LD_GENERATE_MAP_FILE=YES"]


def run_build(derived_data, limit_minutes):
    """Runs the device build from the repository's root, with xcodebuild's output on this one's, and returns its exit
    status (124 when it outlived `limit_minutes` and was stopped)."""
    process = subprocess.Popen(build_command(derived_data), cwd=ROOT)
    try:
        return process.wait(timeout=limit_minutes * 60)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        return 124


def absolute_derived_data(path):
    """`path` (a --derived-data argument) as an absolute path, a relative one taken from the folder the tool was run in:
    xcodebuild is given MODULE_CACHE_DIR, OBJROOT, and SYMROOT inside it, and resolves a relative one against its own
    working folders (a build service's bundle, a package checkout), where the build fails with "Permission denied"."""
    return os.path.abspath(path)


def exit_status(app_bytes, check):
    """The exit status for a measured app: 3 when `check` is asked and the app is over the strict limit, else 0 (a size
    between the limits only warns, in the report)."""
    return 3 if check and app_bytes > STRICT_LIMIT_MB * MEGABYTE else 0


def main(argv=None):
    """The command line: `measure`, `build`, or `--selftest`."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--selftest", action="store_true", help="run the tool's own tests and exit")
    sub = parser.add_subparsers(dest="command")
    measure = sub.add_parser("measure", help="measure a built .app")
    measure.add_argument("app")
    measure.add_argument("--ipa", action="store_true", help="also zip it as an .ipa and estimate the download")
    measure.add_argument("--ipa-out", help="keep the .ipa at this path (implies --ipa)")
    measure.add_argument("--link-map", help="a linker map to split the executable by library")
    measure.add_argument("--top", type=int, default=DEFAULT_TOP)
    measure.add_argument("--json", action="store_true")
    measure.add_argument("--summary", action="store_true", help="print the lines a run's ios-summary.txt carries")
    measure.add_argument("--check", action="store_true", help="exit 3 when the app is over the strict limit")
    build = sub.add_parser("build", help="build the iPhone app for a device, then measure it")
    build.add_argument("--derived-data", default=str(DEFAULT_DERIVED_DATA),
                       help="the build's derived data folder (default: build/ios-size-DerivedData of the repository)")
    build.add_argument("--limit-minutes", type=int, default=DEFAULT_BUILD_LIMIT_MINUTES)
    build.add_argument("--top", type=int, default=DEFAULT_TOP)
    build.add_argument("--json", action="store_true")
    build.add_argument("--summary", action="store_true", help="print the lines a run's ios-summary.txt carries")
    build.add_argument("--check", action="store_true", help="exit 3 when the app is over the strict limit")
    args = parser.parse_args(argv)
    if args.selftest:
        return selftest()
    if args.command == "build":
        started = time.monotonic()
        args.derived_data = absolute_derived_data(args.derived_data)
        status = run_build(args.derived_data, args.limit_minutes)
        if status != 0:
            print(f"iPhone app size: the device build failed (exit status {status}).", file=sys.stderr)
            return 1
        app = Path(args.derived_data) / "Build" / "Products" / PRODUCTS_FOLDER / APP_NAME
        result_args = dict(want_ipa=True, link_map=find_link_map(args.derived_data), top=args.top)
        label = "iPhone app"
        build_minutes = (time.monotonic() - started) / 60
    elif args.command == "measure":
        app = Path(args.app)
        result_args = dict(want_ipa=args.ipa, ipa_out=args.ipa_out, link_map=args.link_map, top=args.top)
        label = "App"
        build_minutes = None
    else:
        parser.print_usage(sys.stderr)
        return 2
    if not app.is_dir():
        print(f"app-size: no app at {app}", file=sys.stderr)
        return 1
    result = measure_app(app, **result_args)
    if build_minutes is not None:
        result["build_minutes"] = round(build_minutes, 1)
    if args.json:
        print(json.dumps(result, indent=2))
    elif args.summary:
        print("\n".join(summary_lines(result, label)))
    else:
        print("\n".join(format_report(result, label)))
    return exit_status(result["app_bytes"], args.check)


# ---------------------------------------------------------------------------
# Self-tests: a made-up bundle in a temporary folder, no real build.
# ---------------------------------------------------------------------------

# A made-up linker map, in the shape Xcode's LD_GENERATE_MAP_FILE writes.
SAMPLE_LINK_MAP = """# Path: /x/TextMouth
# Arch: arm64
# Object files:
[  0] linker synthesized
[  1] /x/Intermediates/TextMouth.build/Release-iphoneos/TextMouthiOS.build/Objects-normal/arm64/App.o
[  2] /x/Products/Release-iphoneos/libmp3lame.a(util.o)
[  3] /x/Products/Release-iphoneos/libmp3lame.a(vbrtag.o)
[  4] /x/Intermediates/TextMouth.build/Release-iphoneos/ZIPFoundation.build/Objects-normal/arm64/Zip.o
[  5] /x/Products/Release-iphoneos/cmark-gfm.o
# Sections:
# Address\tSize    \tSegment\tSection
0x100000000\t0x00001000\t__TEXT\t__text
# Symbols:
# Address\tSize    \tFile  Name
0x100000000\t0x00000100\t[  1] _main
0x100000100\t0x00000200\t[  2] _lame_init
0x100000300\t0x00000100\t[  3] _lame_tag
0x100000400\t0x00000080\t[  4] _zip
0x100000480\t0x00000010\t[  0] _stub
0x100000490\t0x00000040\t[  5] _cmark
# Dead Stripped Symbols:
#        \tSize    \tFile  Name
<<dead>>\t0x00099999\t[  1] _gone
"""


def make_sample_bundle(folder):
    """Makes a made-up iPhone bundle in `folder`: a Mach-O executable of random bytes (which do not compress), a
    compressible text file, a symbolic link that must not count, and a file in a subfolder. Returns the bundle's path
    and the sizes of its regular files."""
    app = Path(folder) / APP_NAME
    (app / "Licenses" / "Lib").mkdir(parents=True)
    executable = b"\xcf\xfa\xed\xfe" + os.urandom(40_000)
    (app / "TextMouth").write_bytes(executable)
    (app / "Info.plist").write_bytes(b"<plist>" + b"abc" * 5_000 + b"</plist>")
    (app / "Licenses" / "Lib" / "LICENSE").write_bytes(b"licence text\n" * 100)
    os.symlink("Info.plist", app / "Link.plist")
    return app, {"TextMouth": len(executable), "Info.plist": 7 + 15_000 + 8, "Licenses/Lib/LICENSE": 1_300}


def selftest():
    """Checks the measuring on a made-up bundle. Returns 0 when every check holds, and prints each failure."""
    failures = []

    def check(condition, message):
        """Records `message` as a failure when `condition` is false."""
        if not condition:
            failures.append(message)

    with tempfile.TemporaryDirectory() as folder:
        app, sizes = make_sample_bundle(folder)
        total = sum(sizes.values())
        # (a) The app: the regular files' sizes added, the symbolic link not counted, as `find -type f` does.
        result = measure_app(app, want_ipa=True, link_map=None, top=2)
        check(result["app_bytes"] == total, f"app bytes {result['app_bytes']} is not {total}")
        check(result["file_count"] == 3, f"file count {result['file_count']} is not 3 (a link must not count)")
        # (d) The biggest files, biggest first, cut to `top`.
        check([path for path, _ in result["top_files"]] == ["TextMouth", "Info.plist"],
              f"top files were {result['top_files']}")
        # (b) The IPA: smaller than the app (the text compresses), and the file's real size when it is kept.
        kept = Path(folder) / "TextMouth.ipa"
        again = measure_app(app, ipa_out=kept)
        check(again["ipa_bytes"] == kept.stat().st_size, "the kept .ipa's size is not the one reported")
        check(again["ipa_bytes"] == result["ipa_bytes"], "an in-memory and a kept .ipa differ in size")
        check(result["ipa_bytes"] < result["app_bytes"] + 1_000, "the IPA is larger than the app plus its headers")
        with zipfile.ZipFile(kept) as archive:
            names = archive.namelist()
        check(f"Payload/{APP_NAME}/TextMouth" in names, f"the IPA's names are {names}")
        check(all(name.startswith(f"Payload/{APP_NAME}/") for name in names), "an entry is outside Payload/")
        # (c) The download: the executable counts at full size, so it is the IPA plus what its deflating saved.
        saved = sizes["TextMouth"] - next(compressed for name, compressed, _, _ in
                                          make_ipa(app, regular_files(app), io.BytesIO())[0]
                                          if name.endswith("/TextMouth"))
        check(result["store_bytes"] == result["ipa_bytes"] + saved, "the download estimate is not the IPA plus the executable's saving")
        check(result["macho_bytes"] == sizes["TextMouth"], "only the executable is Mach-O in the sample")
        # Mach-O detection: a thin magic, a fat one, a Java class, text, an empty file.
        probe = Path(folder) / "probe"
        for content, expected in ((b"\xcf\xfa\xed\xfe" + b"x" * 8, True),
                                  (b"\xca\xfe\xba\xbe\x00\x00\x00\x02rest", True),
                                  (b"\xca\xfe\xba\xbe\x00\x00\x00\x34rest", False),
                                  (b"hello world", False), (b"", False)):
            probe.write_bytes(content)
            check(is_macho(probe) == expected, f"is_macho({content[:8]!r}) is not {expected}")
        # The link map: sizes by library, dead-stripped symbols left out, biggest first.
        map_file = Path(folder) / "map.txt"
        map_file.write_text(SAMPLE_LINK_MAP)
        by_library = parse_link_map(map_file.read_text())
        check(by_library == [("libmp3lame.a", 0x300), ("TextMouthiOS", 0x100), ("ZIPFoundation", 0x80),
                             ("cmark-gfm", 0x40), ("linker synthesized", 0x10)], f"libraries were {by_library}")
        with_map = measure_app(app, link_map=map_file)
        check(with_map["executable_bytes"] == sizes["TextMouth"], "the executable's size is not found by the app's name")
        # The report names the sizes, the limits, and the libraries.
        text = "\n".join(format_report({**result, **with_map}, "iPhone app"))
        check("iPhone app:" in text and f"within the {LIMIT_MB} MB limit" in text, f"report was {text}")
        check("libmp3lame.a" in text and "App Store download" in text, "report lacks a part")
    # The summary lines: three headlines, then details, each with its prefix.
    lines = summary_lines({**result, **with_map}, "iPhone app")
    check(len([line for line in lines if line.startswith(SUMMARY_PREFIX)]) == 3, f"headline lines were {lines}")
    check(all(line.startswith((SUMMARY_PREFIX, SUMMARY_DETAIL_PREFIX)) for line in lines), f"a line has no prefix: {lines}")
    check(any(line.startswith(SUMMARY_DETAIL_PREFIX) and "libmp3lame.a" in line for line in lines), "no library detail line")
    # The limits' words.
    check(f"within the {LIMIT_MB} MB limit" == verdict(LIMIT_MB * MEGABYTE), "30 MB itself is within the limit")
    check(f"over the {LIMIT_MB} MB limit" in verdict(LIMIT_MB * MEGABYTE + 1), "30 MB and a byte is over the limit")
    check(f"over the strict {STRICT_LIMIT_MB} MB limit" == verdict(STRICT_LIMIT_MB * MEGABYTE + 1), "40 MB and a byte is over the strict limit")
    check(exit_status(STRICT_LIMIT_MB * MEGABYTE, True) == 0 and exit_status(STRICT_LIMIT_MB * MEGABYTE + 1, True) == 3
          and exit_status(STRICT_LIMIT_MB * MEGABYTE + 1, False) == 0 and exit_status((LIMIT_MB + 1) * MEGABYTE, True) == 0,
          "--check's status is 3 only above the strict limit")
    check(describe(18_453_210) == "18.5 MB (18,453,210 bytes)", f"describe gave {describe(18_453_210)}")
    # The build's argv: the device SDK, unsigned, a link map, the scheme.
    argv = build_command("/x/dd")
    check("MODULE_CACHE_DIR=/x/dd/ModuleCache.noindex" in argv and "DEPLOYMENT_POSTPROCESSING=YES" in argv and "SYMROOT=/x/dd/Build/Products" in argv and "OBJROOT=/x/dd/Build/Intermediates.noindex" in argv
          and "-derivedDataPath" not in argv and "iphoneos" in argv and "TextMouthiOS" in argv and "-scheme" not in argv and "ARCHS=arm64" in argv and "-destination" not in argv and "CODE_SIGNING_ALLOWED=NO" in argv and "LD_GENERATE_MAP_FILE=YES" in argv,
          f"build command was {argv}")
    # The derived data folder reaches xcodebuild absolute, whichever way it was given (a relative one failed `make ios-size`).
    check(DEFAULT_DERIVED_DATA.is_absolute() and absolute_derived_data(str(DEFAULT_DERIVED_DATA)) == str(DEFAULT_DERIVED_DATA),
          "the default derived data folder is not absolute")
    check(absolute_derived_data("build/ios-size-DerivedData") == os.path.join(os.getcwd(), "build", "ios-size-DerivedData"),
          "a relative --derived-data was not made absolute")
    relative_argv = build_command(absolute_derived_data("build/x"))
    check(all(os.path.isabs(part.split("=", 1)[1]) for part in relative_argv if part.startswith(("SYMROOT=", "OBJROOT=", "MODULE_CACHE_DIR=")))
          and os.path.isabs(relative_argv[relative_argv.index("-clonedSourcePackagesDirPath") + 1]),
          f"a build path stayed relative: {relative_argv}")
    # main() hands the build that absolute folder: a build that fails at once stands in for the real one, and records it.
    given = []
    real_run_build = globals()["run_build"]
    globals()["run_build"] = lambda derived_data, limit_minutes: (given.append(derived_data), 1)[1]
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            main(["build", "--derived-data", "build/x"])
            main(["build"])
    finally:
        globals()["run_build"] = real_run_build
    check(len(given) == 2 and all(os.path.isabs(path) for path in given) and given[1] == str(DEFAULT_DERIVED_DATA),
          f"main gave the build {given}, not absolute folders")
    # The limits are read from check.sh, which defines each once.
    check(limits_from_gate("readonly APP_SIZE_WARNING_MB=12\nreadonly APP_SIZE_LIMIT_MB=34\n") == (12, 34),
          "the limits were not read from a script's text")
    try:
        limits_from_gate("readonly APP_SIZE_WARNING_MB=12\n")
        check(False, "a script without the strict limit was accepted")
    except ValueError:
        pass
    check(limits_from_gate((ROOT / "Scripts" / "check.sh").read_text()) == (LIMIT_MB, STRICT_LIMIT_MB),
          "the limits here are not check.sh's")
    for failure in failures:
        print(f"app-size selftest FAILED: {failure}")
    if not failures:
        print("app-size selftest passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
