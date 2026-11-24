#!/usr/bin/env python3
"""size_settings.py: the compiler and linker settings that make a Release build smaller, defined once.

Both the Makefile's build rule (the Mac app) and Scripts/ios/app-size.py (the iPhone app's Release build) pass
these on xcodebuild's command line, so that they reach every target and every Swift package alike: project.yml
cannot set a package's build settings. They are for Release only; Debug, where the tests run, keeps its own.

Measured by the study of November 23, 2026 (research/SWIFT-SIZE-FLAGS-2026-11-23.md), one unsigned Release build
with all of them against the baseline of -Osize alone: the Mac app 22,295,720 to 18,125,080 bytes, the iPhone
app 17,171,842 to 13,834,194.

Usage (Python 3 standard library only):
    python3 -I -B Scripts/size_settings.py          # the settings as shell-quoted words, for the Makefile
    python3 -I -B Scripts/size_settings.py --list   # one NAME=VALUE per line
    python3 -I -B Scripts/size_settings.py --without NAME[,NAME]   # leave settings out (the goldens' build)
    python3 -I -B Scripts/size_settings.py --help   # the usage
A name --without does not know, or any other argument, is refused with exit status 2.
"""
import shlex
import sys

# Each entry: (name, value, what it does and what it saved). Order is the order passed to xcodebuild.
# Reflection metadata is left at its default, with names (see the note below SETTINGS).
# The savings are the study's, in bytes on the Mac app and the iPhone app, measured on top of the others.
SETTINGS = (
    # Full link-time optimization of the Swift code, packages included: the optimizer sees the whole program at
    # link time and drops what nothing reaches. Alone it saved 3,852,848 bytes on the Mac and 2,827,168 on the
    # iPhone, the largest single saving; it makes the link longer and the optimizer's output only testable in
    # Release (Scripts/test/release-goldens.sh).
    ("SWIFT_LTO", "YES"),
    # The same for the C code (LAME, liblouis, the braille helper): 67,072 bytes on the Mac with the next setting.
    ("LLVM_LTO", "YES"),
    # -Oz for the C code, the smallest: LAME and liblouis run a little slower, which no one hears.
    ("GCC_OPTIMIZATION_LEVEL", "z"),
    # The experimental compiler flags, in FRONTEND_FLAGS below, are joined into this one setting.
)

# NOT adopted: SWIFT_REFLECTION_METADATA_LEVEL=without-names (the study's 132,096 bytes alone on the Mac). It drops the names of enum cases and stored properties, so `"\(error)"` and
# `String(describing:)` then show only a type's name: 28 debug-log lines print an error or a case that way, and the
# user's problem reports depend on those lines. Every future error enum would need its name written out by hand for
# 0.13 MB, so names stay (the orchestrator's decision of November 23, 2026). Three places that stored or logged a
# name through reflection are written out anyway (PhoneImportQuestion.Choice.id, AudioEditError.caseName,
# RecordingCaptureError.description), pinned by ReflectionNamesTests.

# Experimental frontend flags, each passed as `-Xfrontend FLAG`, with what it does and saved. Together they saved
# 151,712 bytes on the Mac app on top of full LTO (the study measured the pair, not each alone).
FRONTEND_FLAGS = (
    # Do not keep a runtime record (a protocol conformance, a type) that nothing refers to.
    "-conditional-runtime-records",
    # Make public symbols internal at link time, so the optimizer may drop them. The app links no client of its own
    # public API, so nothing needs them; but the hosted test bundle links against the app's symbols and does, so
    # Scripts/test/release-goldens.sh leaves this flag out.
    "-internalize-at-link",
)

# The flags no test bundle can link against: the goldens' build leaves these out (see release-goldens.sh).
LEFT_OUT_FOR_TESTS = ("-internalize-at-link",)


def settings(without=()):
    """The settings as `NAME=VALUE` strings, in order. `without` names settings (by name) and frontend flags (by
    flag) to leave out; OTHER_SWIFT_FLAGS goes with its last flag."""
    out = [f"{name}={value}" for name, value in SETTINGS if name not in without]
    flags = [flag for flag in FRONTEND_FLAGS if flag not in without]
    if flags and "OTHER_SWIFT_FLAGS" not in without:
        out.append("OTHER_SWIFT_FLAGS=$(inherited) " + " ".join(f"-Xfrontend {flag}" for flag in flags))
    return out


USAGE = """usage: size_settings.py [--list] [--without NAME[,NAME...]]

Prints the Release size settings, as shell-quoted words on one line (the Makefile's form), or one NAME=VALUE per
line with --list. --without leaves out settings by name (SWIFT_LTO) and frontend flags by flag
(-internalize-at-link), joined by commas; its value is the next argument, or follows an equals sign."""


class UsageError(Exception):
    """A command line this script does not understand: it is refused, never guessed at."""


def known_names():
    """Every name --without takes: each setting's name, each frontend flag, and OTHER_SWIFT_FLAGS, which holds
    the flags."""
    return {name for name, _ in SETTINGS} | set(FRONTEND_FLAGS) | {"OTHER_SWIFT_FLAGS"}


def parse(argv):
    """`(list_form, without)` from the command line. Raises UsageError for an argument it does not know, a
    --without with no name, or a name that is neither a setting nor a flag, so that no typo can leave a setting
    in without a word. A parser of options is not used because the flags begin with a dash, which it would read
    as an option of its own: `--without -internalize-at-link` is the goldens' build's command line."""
    list_form = False
    without = []
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument == "--list":
            list_form = True
        elif argument == "--without" or argument.startswith("--without="):
            if argument == "--without":
                index += 1
                if index == len(argv):
                    raise UsageError("--without needs a name, or names joined by commas")
                value = argv[index]
            else:
                value = argument[len("--without="):]
            names = [name for name in value.split(",") if name]
            if not names:
                raise UsageError("--without needs a name, or names joined by commas")
            unknown = [name for name in names if name not in known_names()]
            if unknown:
                raise UsageError("--without names no setting or flag: " + ", ".join(unknown))
            without += names
        else:
            raise UsageError("unknown argument: " + argument)
        index += 1
    return list_form, tuple(without)


def main(argv):
    """Prints the settings: shell-quoted on one line by default (what the Makefile's $(shell) takes), one per
    line with --list, less those --without names; or the usage, for -h or --help. Returns the exit status: 0,
    or 2 for a command line it refuses, with nothing on standard output."""
    if "-h" in argv or "--help" in argv:
        print(USAGE)
        return 0
    try:
        list_form, without = parse(argv)
    except UsageError as error:
        print(f"size_settings.py: {error}\n\n{USAGE}", file=sys.stderr)
        return 2
    if list_form:
        print("\n".join(settings(without)))
    else:
        print(" ".join(shlex.quote(item) for item in settings(without)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
