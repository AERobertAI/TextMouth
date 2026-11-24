#!/usr/bin/env python3
"""size_settings.py: the compiler and linker settings that make a Release build smaller, defined once.

Both the Makefile's build rule (the Mac app) and Scripts/ios/app-size.py (the iPhone app's Release build) pass
these on xcodebuild's command line, so that they reach every target and every Swift package alike: project.yml
cannot set a package's build settings. They are for Release only; Debug, where the tests run, keeps its own.

Measured by the study of November 23, 2026 (research/SWIFT-SIZE-FLAGS-2026-11-23.md), one unsigned Release build
with all of them against the baseline of -Osize alone: the Mac app 22,295,720 to 18,125,080 bytes, the iPhone
app 17,171,842 to 13,834,194.

A build takes them by its profile (PROFILES, below): "full" takes every setting; "light" takes only those that
cost no memory at link time; "auto", the default, is full on GitHub Actions and light anywhere else. Full
link-time optimization's last step, the link, takes several GB of memory, which can freeze a Mac with 8 GB, so
the Makefile builds full only for `make install` and `make release`, the app that ships.

Usage (Python 3 standard library only):
    python3 -I -B Scripts/size_settings.py          # the settings as shell-quoted words, for the Makefile
    python3 -I -B Scripts/size_settings.py --list   # one NAME=VALUE per line
    python3 -I -B Scripts/size_settings.py --without NAME[,NAME]   # leave settings out (the goldens' build)
    python3 -I -B Scripts/size_settings.py --profile full|light|auto   # the profile (default auto)
    python3 -I -B Scripts/size_settings.py --which  # the profile the build would take: full or light
    python3 -I -B Scripts/size_settings.py --help   # the usage
A name --without does not know, a profile --profile does not know, or any other argument, is refused with exit
status 2.
"""
import os
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

# The profiles a build may take (the user's decisions of November 24, 2026). Full link-time optimization's link
# takes several GB of memory, and with other apps open it froze a Mac with 8 GB, so the builds a Mac makes for
# development (`make build`, `make check`, the golden tests, `make ios-size`) are light, and the app that ships
# is full: `make install` and `make release` on a Mac, and every build on GitHub Actions.
FULL = "full"
LIGHT = "light"
AUTO = "auto"
PROFILES = (FULL, LIGHT, AUTO)

# What a light build keeps: the settings that make no work at link time. The frontend flags were measured and
# tested (release-goldens.sh) only with full link-time optimization, so a light build leaves them out too.
LIGHT_SETTINGS = ("GCC_OPTIMIZATION_LEVEL",)


class UsageError(Exception):
    """A command line this script does not understand: it is refused, never guessed at."""


def resolved(profile=AUTO, environ=None):
    """FULL or LIGHT, the profile a build of `profile` takes: "auto" is full on GitHub Actions, which sets
    GITHUB_ACTIONS to "true" on every runner, and light anywhere else. Raises UsageError for a profile it does not
    know, so that no typo can choose one without a word."""
    if profile not in PROFILES:
        raise UsageError(f"--profile is one of {', '.join(PROFILES)}, not {profile!r}")
    if profile != AUTO:
        return profile
    environ = os.environ if environ is None else environ
    return FULL if environ.get("GITHUB_ACTIONS") == "true" else LIGHT


def settings(without=(), profile=AUTO, environ=None):
    """The settings of `profile` as `NAME=VALUE` strings, in order. `without` names settings (by name) and
    frontend flags (by flag) to leave out; OTHER_SWIFT_FLAGS goes with its last flag. A light build keeps only
    LIGHT_SETTINGS, and none of the frontend flags."""
    full = resolved(profile, environ) == FULL
    out = [f"{name}={value}" for name, value in SETTINGS
           if name not in without and (full or name in LIGHT_SETTINGS)]
    flags = [flag for flag in FRONTEND_FLAGS if flag not in without] if full else []
    if flags and "OTHER_SWIFT_FLAGS" not in without:
        out.append("OTHER_SWIFT_FLAGS=$(inherited) " + " ".join(f"-Xfrontend {flag}" for flag in flags))
    return out


USAGE = """usage: size_settings.py [--list] [--without NAME[,NAME...]] [--profile full|light|auto] [--which]

Prints the Release size settings of a profile, as shell-quoted words on one line (the Makefile's form), or one
NAME=VALUE per line with --list. --without leaves out settings by name (SWIFT_LTO) and frontend flags by flag
(-internalize-at-link), joined by commas. --profile chooses the profile: full takes every setting, light only
those that cost no memory at link time, and auto (the default) is full on GitHub Actions and light anywhere
else. --which prints the profile the build would take, full or light, in place of the settings. The value of
--without and of --profile is the next argument, or follows an equals sign."""


def known_names():
    """Every name --without takes: each setting's name, each frontend flag, and OTHER_SWIFT_FLAGS, which holds
    the flags."""
    return {name for name, _ in SETTINGS} | set(FRONTEND_FLAGS) | {"OTHER_SWIFT_FLAGS"}


def option_value(argv, index, option):
    """`(value, next index)` of `option` at `argv[index]`, whose value is the next argument or follows an equals
    sign; None when `argv[index]` is not that option. Raises UsageError when the value is missing."""
    argument = argv[index]
    if argument == option:
        if index + 1 == len(argv):
            raise UsageError(f"{option} needs a value")
        return argv[index + 1], index + 2
    if argument.startswith(option + "="):
        return argument[len(option) + 1:], index + 1
    return None


def parse(argv):
    """`(list_form, without, profile, which)` from the command line. Raises UsageError for an argument it does not
    know, a --without with no name, or a name that is neither a setting nor a flag, so that no typo can leave a
    setting in without a word; a profile it does not know is refused by `resolved`. A parser of options is not
    used because the flags begin with a dash, which it would read as an option of its own:
    `--without -internalize-at-link` is the goldens' build's command line."""
    list_form, which, profile = False, False, AUTO
    without = []
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument == "--list":
            list_form, index = True, index + 1
        elif argument == "--which":
            which, index = True, index + 1
        elif (found := option_value(argv, index, "--without")) is not None:
            value, index = found
            names = [name for name in value.split(",") if name]
            if not names:
                raise UsageError("--without needs a name, or names joined by commas")
            unknown = [name for name in names if name not in known_names()]
            if unknown:
                raise UsageError("--without names no setting or flag: " + ", ".join(unknown))
            without += names
        elif (found := option_value(argv, index, "--profile")) is not None:
            profile, index = found
        else:
            raise UsageError("unknown argument: " + argument)
    return list_form, tuple(without), profile, which


def main(argv):
    """Prints the settings of the profile: shell-quoted on one line by default (what the Makefile's $(shell)
    takes), one per line with --list, less those --without names; or the profile the build would take, for
    --which; or the usage, for -h or --help. Returns the exit status: 0, or 2 for a command line it refuses, with
    nothing on standard output."""
    if "-h" in argv or "--help" in argv:
        print(USAGE)
        return 0
    try:
        list_form, without, profile, which = parse(argv)
        chosen = resolved(profile)
    except UsageError as error:
        print(f"size_settings.py: {error}\n\n{USAGE}", file=sys.stderr)
        return 2
    if which:
        print(chosen)
    elif list_form:
        print("\n".join(settings(without, chosen)))
    else:
        print(" ".join(shlex.quote(item) for item in settings(without, chosen)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
