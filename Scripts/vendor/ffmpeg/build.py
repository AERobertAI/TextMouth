#!/usr/bin/env python3
"""build.py: builds the FFmpeg libraries TextMouth links (FMT50), from a pinned release.

Usage:
    python3 -I -B Scripts/vendor/ffmpeg/build.py --xcode
    python3 -I -B Scripts/vendor/ffmpeg/build.py --platform macosx --work DIR [--tarball FILE] [--jobs N]
    python3 -I -B Scripts/vendor/ffmpeg/build.py --print-configure --platform macosx
    python3 -I -B Scripts/vendor/ffmpeg/build.py --readme [--check]
    python3 -I -B Scripts/vendor/ffmpeg/build.py --check-signature --tarball FILE --signature FILE.asc

  --xcode            what the FFmpeg library targets' build phase runs (project.yml): the
                     platform is Xcode's PLATFORM_NAME, and the work folder $OBJROOT/FFmpeg,
                     inside the build's DerivedData, so GitHub's cache of DerivedData keeps it.
  --platform NAME    macosx, iphoneos, or iphonesimulator (Xcode's names).
  --work DIR         where the download, the unpacked release, the builds, and the
                     published libraries go (see "The work folder" below).
  --tarball FILE     the release's tarball, when one is at hand; it is checked like a download.
  --jobs N           how many files make compiles at once (default 4).
  --print-configure  print the configure line of --platform and exit; builds nothing.
  --readme           write Vendor/package-licenses/FFmpeg/README, which both apps ship
                     beside FFmpeg's licence; with --check, write nothing and exit 1 when it
                     differs from what this script would write.
  --check-signature  check the tarball against its OpenPGP signature with gpg and the
                     fingerprint pinned below; for whoever changes the pin.

What it builds. The pin below names one FFmpeg release, by its URL, its SHA-256, and its size,
and the fingerprint of the key that signs FFmpeg's releases, then a second place to download
the same release (FFmpeg's mirror on GitHub, its archive of the release's tag, with a pin of
its own), tried when ffmpeg.org gives nothing usable, and five upstream patches (PATCHES), each
pinned by its SHA-256 and applied to the unpacked release. The archive is downloaded once and
must match a pin's SHA-256, or nothing is built. FFmpeg's own configure then builds only what
TextMouth's import reads, the "parity" set of research/FFMPEG-MINIMAL-RESEARCH-2026-11-16.md:
every container the installed ffmpeg converted at import, with each one's common codecs, all of
it under the LGPL 2.1 or later (no --enable-gpl, --enable-nonfree, or --enable-version3). It
builds static libraries, for arm64 only, for the Mac (macOS 14.0) and the iPhone and its
simulator (iOS 26.0), and merges the four libraries (libavformat, libavcodec, libswresample,
libavutil) into one archive, libtmffmpeg.a, whose members are named uniquely, since FFmpeg's
libraries share object names (utils.o, options.o) that a plain merge would warn about.

No path of the building Mac. configure records its command line in the libraries
(av*_configuration()), and FFmpeg's sources name their own files (__FILE__). So the configure
line holds no absolute path at all: the compiler is a small wrapper found on PATH (tmff-cc,
written into the work folder), which finds the SDK through SDKROOT and maps the work folder
away with -ffile-prefix-map and -fdebug-prefix-map; the prefix is configure's default; the
files are installed with DESTDIR, which configure never sees. After the build, `strings` must
find no home folder, checkout, temporary folder, or work folder in the archive or the headers,
or the build fails.

When it builds again. Each build has a key, the SHA-256 of the pin, the configure line, the
platform, this script's RECIPE number, the compiler's version, and the patches: a published build
whose key is the same is kept, and the script ends at once, so an ordinary build of the app pays
nothing, and a change of the patches rebuilds.

The shared folder. The release's archive and its unpacked source are the same for every
checkout and every build folder of a Mac, so they are kept once, in build/ffmpeg/ of the main
checkout (git's common directory names it, from any worktree), and every build reads them there:
    SHARED/download/ffmpeg-<version>.tar.xz   the release from ffmpeg.org, checked, or
    SHARED/download/ffmpeg-<version>-github.tar.gz   the archive of its tag from GitHub, checked
    SHARED/source/<key>/ffmpeg-<version>/     the release, unpacked and patched once; <key> is
                                              of the release's SHA-256 and the patches, so a
                                              changed list of patches unpacks afresh, beside
                                              the old one, and two checkouts never unpack over
                                              each other (a lock is held while one does)
FFmpeg is built outside its source (configure runs in the build folder), so the shared source is
only read: a second build folder unpacks nothing and copies nothing. Outside a git checkout
there is no shared folder, and the same names are under WORK instead.

The work folder:
    WORK/build-<platform>-<key>/              configure, make, and make install's DESTDIR
    WORK/<platform>/include/                  FFmpeg's public headers, and textmouth_ffmpeg_build.h
    WORK/<platform>/lib/libtmffmpeg.a         the merged libraries
    WORK/<platform>/build.json, key           the record of the build, and its key, written last

The script deletes nothing: it writes into fixed folders, a new build folder for each key, and
replaces only its own published files. Under Xcode it holds a lock in the work folder, so two
builds never write the same folder at once.

FFmpeg's code is not read or copied here: only its release is downloaded, checked, and built,
and its documentation (configure --help) names the options used.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

sys.dont_write_bytecode = True

# ---------------------------------------------------------------------------
# The pin
# ---------------------------------------------------------------------------

# FFmpeg 9.0.2 (September 18, 2026), the newest release on November 16, 2026. To move to a new
# point release: change these four lines and the GITHUB_ pin after them (compare the two trees
# again, as the comment there says), drop the PATCHES the release includes, check its signature (--check-signature, with the key
# below fetched from ffmpeg.org's download page and a keyserver), run this script, compare the
# release's LICENSE.md and COPYING.LGPLv2.1 with Vendor/package-licenses/FFmpeg (the script
# fails when they differ), write the README again (--readme), and run the tests.
FFMPEG_VERSION = "9.0.2"
FFMPEG_URL = f"https://ffmpeg.org/releases/ffmpeg-{FFMPEG_VERSION}.tar.xz"
FFMPEG_SHA256 = "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
FFMPEG_TARBALL_BYTES = 12_040_788

# A second place to download the same release from, tried when ffmpeg.org cannot be reached or
# gives a file that is not the pin: FFmpeg's own mirror on GitHub, the archive it makes of the
# release's tag (n9.0.2), with a pin of its own (GitHub makes the archive from the tag, not from
# the release's tarball, so its bytes and its top folder, FFmpeg-n9.0.2, differ). Compared on
# November 17, 2026, each unpacked into a new empty folder, the two trees differ only so:
#   - VERSION (the text "9.0.2") is in ffmpeg.org's tarball alone; RELEASE (the same text) is in both;
#   - GitHub's archive holds git's own files, which the tarball leaves out: .gitattributes and
#     25 .gitignore files (the top folder's and those of doc/, doc/doxy/, doc/examples/, ffbuild/,
#     fftools/resources/, libavcodec/, libavcodec/tests/, libavdevice/, libavdevice/tests/,
#     libavfilter/, libavfilter/opencl/, libavfilter/tests/, libavfilter/vulkan/, libavformat/,
#     libavformat/tests/, libavutil/, libavutil/tests/, libswresample/tests/, libswscale/aarch64/,
#     libswscale/tests/, tests/, tests/api/, tests/checkasm/, and tools/);
#   - no file the two share differs by a byte (10,398 files).
# The archive was downloaded twice and was the same both times. A GitHub archive is made on
# demand, so its bytes are not promised for ever: if GitHub ever changes them, the pin below
# stops this source with a plain refusal (never a build), and ffmpeg.org's still serves.
GITHUB_URL = f"https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n{FFMPEG_VERSION}.tar.gz"
GITHUB_SHA256 = "6e374ed621e48faa40639307dff48ba6fe574a509977956d2cce9669b7cc27e9"
GITHUB_TARBALL_BYTES = 17_319_950
GITHUB_TOP_FOLDER = f"FFmpeg-n{FFMPEG_VERSION}"

# The fixes of FFmpeg's development branch applied to 9.0.2's source before it is built: the five
# CVEs that NVD lists as open in 9.0.2, each fixed on the development branch by the commit NVD
# cites. Each is that commit as GitHub gives it (https://github.com/FFmpeg/FFmpeg/commit/<hash>.patch),
# kept unchanged in Scripts/vendor/ffmpeg/patches/<hash>.patch and pinned here by its SHA-256, and
# applied in this order, with no fuzz, to the unpacked source: one that does not apply fails the
# build. They are part of every build's key, so changing them rebuilds. The licence notices say
# so (the README of Vendor/package-licenses/FFmpeg and the app's Credits).
#
# DROP THESE when FFmpeg 9.0.3 (or a later release) is the pin and includes the five commits:
# empty PATCHES, delete the folder, and let the README say "unmodified" again (the follow-up
# issue FU01 says the same).
PATCHES = [
    # (commit, the CVE it fixes, SHA-256 of the patch file)
    ("968e9e948ed8c9ba90dbc875e60b843c755cf4ba", "CVE-2026-125104", "6e3c7995b54e7e2de339943c742857fc86183780abff662001ab512dbfd57ff7"),
    ("5d59b7c45d7142bddd13ddc8891e72c5c7dc991b", "CVE-2026-125171", "11dcff0ca39589a65dab61f843b2505a9667a98e4cc1e59ae7000dd63dee7ec0"),
    ("7145d13201c9f9c5253f40295714faa4f4ada1a0", "CVE-2026-125182", "70e16648e035f26e6f940f088e313ea3d7027c22fd8801973ece85b8582f5d30"),
    ("972fe1ccd326538fe9a6b5d5094b7880b5443429", "CVE-2026-125221", "c186bd41f88746877d429613fdbdafa37d18442953092b6af664db3e24b63031"),
    ("90f5e61a1da2dcc0050169af8ca593530f26071b", "CVE-2026-125224", "aa28951df1335a46ed12f2324f0bd54a0bb530e1c07e7b62274b96e29079b0fe"),
]

# The fingerprint of FFmpeg's release signing key ("FFmpeg release signing key
# <ffmpeg-devel@ffmpeg.org>"), as ffmpeg.org's download page and the Ubuntu keyserver give it.
# The routine build checks only the SHA-256 above; this is for re-checking the signature
# whenever the pin changes (--check-signature).
SIGNING_KEY_FINGERPRINT = "FCF986EA15E6E293A5644F10B4322F04D67658D8"

# This script's way of building, in a number that is part of every build's key: raise it when a
# change here would build different libraries from the same pin and configure line.
RECIPE = 1

# ---------------------------------------------------------------------------
# What is built
# ---------------------------------------------------------------------------

# The demuxers TextMouth's sniff forces (FFmpegContainer.demuxer): ASF (WMA, WMV), Matroska and
# WebM, Flash video, AVI, RealMedia, Musepack stream versions 7 and 8, and Ogg (Speex, and an
# .spx holding another codec).
DEMUXERS = ["asf", "matroska", "flv", "avi", "rm", "mpc", "mpc8", "ogg"]

# The decoders of what those containers carry (the research's parity set):
# - the five WMA decoders: WMA 1, WMA 2, Pro, Lossless, and Voice;
# - Speex, and Musepack 7 and 8;
# - RealAudio: Cook, ACELP.net (sipr), ATRAC3, RealAudio Lossless, 14.4, and 28.8;
# - the lossy codecs of Matroska, AVI, Flash video, and RealAudio 10: AAC, MP3, MP2, AC-3,
#   E-AC-3, Opus, Vorbis, and DTS;
# - the lossless ones: FLAC, ALAC, TrueHD, MLP, and TTA, WavPack, and Monkey's Audio inside
#   Matroska (TextMouth reads their own files itself);
# - PCM of every common layout, A-law, and mu-law;
# - what only the video files carry: Microsoft and IMA ADPCM, Flash ADPCM, Nellymoser, and
#   Microsoft GSM.
DECODERS = [
    "wmav1", "wmav2", "wmapro", "wmalossless", "wmavoice",
    "speex", "mpc7", "mpc8",
    "cook", "sipr", "atrac3", "ralf", "ra_144", "ra_288",
    "aac", "mp3float", "mp2float", "ac3", "eac3", "opus", "vorbis", "dca",
    "flac", "alac", "truehd", "mlp", "tta", "wavpack", "ape",
    "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be",
    "pcm_f32le", "pcm_f32be", "pcm_f64le", "pcm_f64be", "pcm_u8", "pcm_s8", "pcm_alaw", "pcm_mulaw",
    "adpcm_ms", "adpcm_ima_wav", "adpcm_swf", "nellymoser", "gsm_ms",
]

# The parsers of those codecs, which split a container's packets into frames.
PARSERS = ["aac", "ac3", "cook", "dca", "flac", "gsm", "mlp", "mpegaudio", "opus", "sipr", "vorbis"]

# The libraries the build makes, in the order a linker reads them; libswresample is there for
# the Opus decoder, which configure leaves out without it.
LIBRARIES = ["libavformat", "libavcodec", "libswresample", "libavutil"]

# Whether FFmpeg is built for size (--enable-small, -Os and its own smaller code). On (TL18, November 20, 2026,
# to fit the eleven interface languages in 25 MB). Measured with research/ffmpeg-minimal/build.py on the parity set,
# FFmpeg 9.0.2, as the bytes the libraries add to a linked, stripped program: the Mac's 2,356,208 became 1,766,688
# (589,520 fewer; 591,624 by sections) and the iPhone's 2,274,112 became 1,766,688 (507,424 fewer; 516,220 by
# sections). Decoding the research samples (2 to 6 seconds of audio; best of 25 runs of the whole harness, about
# 10 ms each, so process start-up is most of it) took 3% to 46% longer on seven samples and 12% to 13% less on two
# (the noise is about that size): +6% WMA 2, +3% MP3, +12% AAC, +3% 5.1 AC-3, +10% Opus, +6% Vorbis, +46% Speex,
# +20% RealAudio 1.0, and -13% FLAC, -12% WMA 1. Earlier, with 30-minute stereo samples and the helper, it was 6%
# (WMA 2), 10% (AAC), 12% (5.1 AC-3), and 27% (Opus) slower, FLAC within noise. Either way decoding runs hundreds
# of times faster than playback. The decoded samples are the same as the speed build's (Opus differs from the
# installed ffmpeg by 9e-8 instead of 9e-6, Vorbis, WMA, FLAC, MP3, and AAC are bit-identical).
ENABLE_SMALL = True

# The platforms, by Xcode's PLATFORM_NAME: each one's SDK, the target clang compiles for (arm64,
# at the app's deployment target), whether configure cross-compiles, and the platform every
# object file must say it was built for (LC_BUILD_VERSION).
PLATFORMS = {
    "macosx": {"sdk": "macosx", "target": "arm64-apple-macos14.0", "cross": False, "built_for": "macOS 14.0"},
    "iphoneos": {"sdk": "iphoneos", "target": "arm64-apple-ios26.0", "cross": True, "built_for": "iOS 26.0"},
    "iphonesimulator": {
        "sdk": "iphonesimulator", "target": "arm64-apple-ios26.0-simulator", "cross": True,
        "built_for": "iOS simulator 26.0",
    },
}

# The name of the compiler wrapper the configure line names, found on PATH.
COMPILER_WRAPPER = "tmff-cc"

# The merged archive and the generated header each published build holds.
MERGED_LIBRARY = "libtmffmpeg.a"
BUILD_HEADER = "textmouth_ffmpeg_build.h"

# How many files make compiles at once by default: half of an 8-core Mac that others share.
DEFAULT_JOBS = 4

# The limits of each step's commands, in seconds: generous, for GitHub's slower runners.
CONFIGURE_SECONDS = 900
MAKE_SECONDS = 2400
SHORT_SECONDS = 600

# This script's folder and the repository it is in (Scripts/vendor/ffmpeg is three folders down).
HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parent.parent.parent

# FFmpeg's notices that both apps ship (Licenses/FFmpeg), kept in the repository: the release's
# LICENSE.md and COPYING.LGPLv2.1, unchanged, and the README this script writes.
NOTICES_FOLDER = REPOSITORY / "Vendor" / "package-licenses" / "FFmpeg"
RELEASE_NOTICES = ["LICENSE.md", "COPYING.LGPLv2.1"]

# The upstream patches (PATCHES), each kept as it came from GitHub, named by its commit.
PATCHES_FOLDER = HERE / "patches"


class BuildError(RuntimeError):
    """A step of the build failed; the message says which and why."""


# ---------------------------------------------------------------------------
# The configure line
# ---------------------------------------------------------------------------

def configure_arguments(platform):
    """FFmpeg's configure line for `platform`, as a list of arguments, without configure itself.

    Nothing is enabled but what TextMouth's import reads: no programs, documentation, network,
    or detected outside library, and of FFmpeg's libraries only libavformat, libavcodec,
    libswresample, and libavutil, built static. zlib, which macOS and iOS both provide, is the
    one outside library: Matroska tracks may be compressed with it. No protocol is enabled,
    since the helper reads the file through its own callbacks. The line holds no absolute path:
    the compiler is the wrapper on PATH (`compiler_wrapper_text`).
    """
    target = PLATFORMS[platform]
    compiler = f"{COMPILER_WRAPPER} --target={target['target']}"
    arguments = [
        "--disable-everything", "--disable-autodetect", "--disable-network",
        "--disable-programs", "--disable-doc",
        "--disable-avdevice", "--disable-swscale", "--disable-avfilter",
        "--enable-static", "--disable-shared", "--disable-debug",
        "--enable-zlib",
        f"--cc={compiler}",
        f"--as={compiler}",
    ]
    if target["cross"]:
        arguments += ["--enable-cross-compile", "--target-os=darwin", "--arch=aarch64"]
    if ENABLE_SMALL:
        arguments.append("--enable-small")
    arguments += [f"--enable-demuxer={name}" for name in DEMUXERS]
    arguments += [f"--enable-decoder={name}" for name in DECODERS]
    arguments += [f"--enable-parser={name}" for name in PARSERS]
    return arguments


def shell_line(arguments):
    """`arguments` as one line a shell would read back, each quoted only where it must be."""
    def quoted(argument):
        if re.fullmatch(r"[A-Za-z0-9_@%+=:,./-]+", argument):
            return argument
        return "'" + argument.replace("'", "'\\''") + "'"
    return " ".join(quoted(argument) for argument in arguments)


def compiler_wrapper_text():
    """The text of the compiler wrapper the configure line names (tmff-cc).

    It runs Xcode's clang, which finds the SDK through SDKROOT (the script sets it), and maps
    TMFF_BUILD_ROOT, the work folder, to "." and TMFF_SOURCE_ROOT, the folder the release is
    unpacked in (the shared one, or WORK/source), to "./source" in every path the compiler writes
    (__FILE__, and debug information, though none is made), so no folder of the building Mac
    reaches the libraries, and the paths are the same wherever the source is kept.
    """
    return (
        "#!/bin/sh\n"
        "# Written by Scripts/vendor/ffmpeg/build.py: the compiler FFmpeg's configure line names.\n"
        "# It maps the work folder (TMFF_BUILD_ROOT) and the unpacked source's folder (TMFF_SOURCE_ROOT)\n"
        "# away in every path the compiler writes.\n"
        'exec xcrun clang -ffile-prefix-map="$TMFF_BUILD_ROOT"=. -fdebug-prefix-map="$TMFF_BUILD_ROOT"=. '
        '-ffile-prefix-map="$TMFF_SOURCE_ROOT"=./source -fdebug-prefix-map="$TMFF_SOURCE_ROOT"=./source "$@"\n'
    )


# ---------------------------------------------------------------------------
# Running commands
# ---------------------------------------------------------------------------

def run_text(command, cwd=None, env=None, seconds=SHORT_SECONDS):
    """Runs `command` and returns its standard output; raises BuildError on a failure."""
    try:
        result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True,
                                timeout=seconds, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        raise BuildError(f"{command[0]} could not run: {error}") from error
    if result.returncode != 0:
        raise BuildError(f"{' '.join(command[:3])} failed ({result.returncode}): {result.stderr.strip()[-2000:]}")
    return result.stdout


def run_logged(command, log_path, cwd, env, seconds):
    """Runs `command` with both of its streams written to `log_path`.

    Returns the wall-clock seconds and the processor seconds of the command and every process
    it waited for, which a parallel make's compiles are. Raises BuildError, with the log's last
    lines, when it fails or runs past `seconds`.
    """
    import resource  # Only here: the module is Unix's, and the rest of the script is not.
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.monotonic()
    with open(log_path, "w", encoding="utf-8") as log:
        try:
            status = subprocess.run(command, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=seconds, check=False).returncode
        except subprocess.TimeoutExpired:
            log.write(f"\nbuild.py: stopped after {seconds} seconds\n")
            status = -1
    wall = time.monotonic() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    if status != 0:
        tail = "\n".join(Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines()[-40:])
        raise BuildError(f"{Path(command[0]).name} failed ({status}); the end of {log_path}:\n{tail}")
    return round(wall, 1), round(cpu, 1)


def sdk_path(platform):
    """The path of the SDK `platform` builds with."""
    return run_text(["xcrun", "--sdk", PLATFORMS[platform]["sdk"], "--show-sdk-path"]).strip()


def compiler_version():
    """The first line of `clang --version`: the compiler is part of every build's key."""
    return run_text(["xcrun", "clang", "--version"]).splitlines()[0].strip()


def build_environment(work, platform):
    """The environment configure and make run in: a clean one, so that nothing Xcode exports to
    a build phase (deployment targets, flags, architectures) reaches FFmpeg's build. It holds
    PATH with the wrapper's folder first, SDKROOT, the wrapper's TMFF_BUILD_ROOT and
    TMFF_SOURCE_ROOT, and the few variables a shell and Xcode's tools need."""
    environment = {
        "PATH": f"{work / 'bin'}:/usr/bin:/bin:/usr/sbin:/sbin",
        "SDKROOT": sdk_path(platform),
        "TMFF_BUILD_ROOT": str(work),
        "TMFF_SOURCE_ROOT": str(sources_folder(work)),
        "LANG": "C",
        "LC_ALL": "C",
    }
    for name in ("HOME", "TMPDIR", "DEVELOPER_DIR", "USER"):
        if os.environ.get(name):
            environment[name] = os.environ[name]
    return environment


# ---------------------------------------------------------------------------
# The release: download, check, unpack
# ---------------------------------------------------------------------------

def tarball_name():
    """The release tarball's file name from ffmpeg.org."""
    return f"ffmpeg-{FFMPEG_VERSION}.tar.xz"


def sources():
    """The places the release is downloaded from, in the order they are tried, each as a dict:
    its name, its URL, the file name it is kept under in WORK/download, its pin (SHA-256 and
    size), and the name of the one folder its archive unpacks to. Read from the module's pin when
    asked, so a test can change the pin."""
    return [
        {"name": "ffmpeg.org", "url": FFMPEG_URL, "file": tarball_name(), "sha256": FFMPEG_SHA256,
         "bytes": FFMPEG_TARBALL_BYTES, "folder": f"ffmpeg-{FFMPEG_VERSION}"},
        {"name": "github.com", "url": GITHUB_URL, "file": f"ffmpeg-{FFMPEG_VERSION}-github.tar.gz",
         "sha256": GITHUB_SHA256, "bytes": GITHUB_TARBALL_BYTES, "folder": GITHUB_TOP_FOLDER},
    ]


def digest_of(path):
    """The SHA-256 of the file at `path`, in hexadecimal."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def source_of(path):
    """The source whose pin the file at `path` matches (its size and SHA-256), or None."""
    path = Path(path)
    if not path.is_file():
        return None
    size = path.stat().st_size
    digest = None
    for source in sources():
        if size != source["bytes"]:
            continue
        digest = digest or digest_of(path)
        if digest == source["sha256"]:
            return source
    return None


def is_the_release(path):
    """Whether `path` is the pinned release, from any of its sources: its size and SHA-256
    match a pin."""
    return source_of(path) is not None


def shared_root():
    """The folder every checkout of this Mac shares for FFmpeg's release, in the main checkout's
    build/ folder (git's common directory names it), or None outside a git checkout."""
    sys.path.insert(0, str(REPOSITORY / "Scripts" / "agents"))
    try:
        import repo_paths  # noqa: E402  (imported by path, after sys.path is set)
        return repo_paths.main_checkout(REPOSITORY) / "build" / "ffmpeg"
    except Exception:  # Not a git checkout, or git cannot run: there is no shared folder.
        return None
    finally:
        sys.path.pop(0)


# The folders every checkout of this Mac shares, whichever worktree the script runs from
# (Scripts/agents/tests/test_repo_paths.py holds them to the main checkout's); None outside a
# checkout. The archives of the release are kept in SHARED_DOWNLOADS, its unpacked source in
# SHARED_SOURCES (one folder for each release and list of patches, `unpacked_parent`).
SHARED_ROOT = shared_root()
SHARED_DOWNLOADS = SHARED_ROOT / "download" if SHARED_ROOT is not None else None
SHARED_SOURCES = SHARED_ROOT / "source" if SHARED_ROOT is not None else None


@contextlib.contextmanager
def exclusive(lock_path):
    """Holds an exclusive lock on the file `lock_path` (made if it is missing, and never deleted)
    while the block runs, so two builds, from any checkout, never write the same folder at once."""
    lock_path = Path(lock_path)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def download_folder(work):
    """The folder the release's archive is kept and looked for in: the shared one when there is
    one that can be made, else WORK/download."""
    if SHARED_DOWNLOADS is not None:
        try:
            SHARED_DOWNLOADS.mkdir(parents=True, exist_ok=True)
            return SHARED_DOWNLOADS
        except OSError:  # Not writable: this build keeps its own, as it did before the folder was shared.
            pass
    return work / "download"


def sources_folder(work):
    """The folder the unpacked releases are kept in: the shared one when there is one that can be
    made, else WORK/source."""
    if SHARED_SOURCES is not None:
        try:
            SHARED_SOURCES.mkdir(parents=True, exist_ok=True)
            return SHARED_SOURCES
        except OSError:  # Not writable: this build keeps its own, as it did before the folder was shared.
            pass
    return work / "source"


def is_from(path, source):
    """Whether the file at `path` is the release as `source` gives it (its pin matches)."""
    found = source_of(path)
    return found is not None and found["name"] == source["name"]


def release_tarball(work, given=None):
    """The checked release archive, and the source it is from: `given` when it is the release,
    else one already in the download folder (`download_folder`: the shared one, else WORK/download),
    else a copy kept in WORK/download by a build before the folder was shared, else a new
    download, from each source in turn until one gives the pinned release. A file that is not the
    release is never used, and nothing is built from it. The download folder is locked while a
    file is put in it, so two builds never write the same file. Returns (the archive's path in
    the download folder, source)."""
    folder = download_folder(work)
    folder.mkdir(parents=True, exist_ok=True)

    def kept():
        """The release already in the download folder, as (path, source), or None."""
        for source in sources():
            if is_from(folder / source["file"], source):
                return folder / source["file"], source
        return None

    found = kept()
    if found:
        return found
    with exclusive(folder / ".download.lock"):
        # Another build may have put the release there while this one waited for the lock.
        found = kept()
        if found:
            return found
        if given and Path(given).is_file():
            source = source_of(given)
            if source is None:
                raise BuildError(f"{given} is not FFmpeg {FFMPEG_VERSION}'s release: its SHA-256 is not a pin's")
            copy_replacing(given, folder / source["file"])
            return folder / source["file"], source
        # What an earlier build kept in its own work folder (when that is not the download folder).
        for older in sources():
            candidate = work / "download" / older["file"]
            source = source_of(candidate) if candidate.parent != folder else None
            if source is not None:
                copy_replacing(candidate, folder / source["file"])
                return folder / source["file"], source
        refused = []
        for source in sources():
            wanted = folder / source["file"]
            try:
                download(source["url"], wanted)
            except BuildError as error:
                refused.append(f"{source['name']}: {error}")
                continue
            if is_from(wanted, source):
                return wanted, source
            refused.append(f"{source['name']}: the download of {source['url']} is not the pinned release: "
                           f"its SHA-256 is {digest_of(wanted)}")
        raise BuildError("the release could not be downloaded from any source:\n" + "\n".join(refused))


def download(url, destination):
    """Downloads `url` to `destination` with curl (the system's, whose TLS is current), through
    a partial file that replaces `destination` only once the download ends."""
    partial = destination.with_name(destination.name + ".partial")
    print(f"build.py: downloading {url}", flush=True)
    run_text(["/usr/bin/curl", "--fail", "--location", "--silent", "--show-error", "--retry", "3",
              "--connect-timeout", "30", "--max-time", "600", "--user-agent", "TextMouth-build",
              "--output", str(partial), url], seconds=660)
    os.replace(partial, destination)


def copy_replacing(source, destination):
    """Copies `source` to `destination` through a temporary file beside it, so that a reader
    never sees half a file."""
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.copying")
    shutil.copyfile(source, temporary)
    os.replace(temporary, destination)


def patches_digest():
    """One SHA-256 for the whole list of patches and their order, "none" for no patches: part of
    the folder an unpacked tree is in and of every build's key."""
    if not PATCHES:
        return "none"
    return hashlib.sha256(json.dumps(PATCHES).encode("utf-8")).hexdigest()


def unpacked_parent(work):
    """The folder <source folder>/<key> that holds the unpacked, patched release (`sources_folder`:
    the shared one, else WORK/source): one for each release and list of patches, so a changed
    list unpacks afresh and never lands on a tree the old list patched."""
    key = hashlib.sha256(f"{FFMPEG_SHA256} {patches_digest()}".encode("utf-8")).hexdigest()[:16]
    return sources_folder(work) / key


def unpacked_marker(work):
    """The file saying the release is unpacked and patched in `unpacked_parent`: written only
    once every member was checked and extracted and every patch applied."""
    return unpacked_parent(work) / ".unpacked"


def apply_patches(folder):
    """Applies each pinned patch, in order, to the unpacked release in `folder`. Each patch file
    must be the pinned one (SHA-256), and must apply with no fuzz and no rejected hunk, or the
    build fails. Returns the commits applied."""
    applied = []
    for commit, cve, digest in PATCHES:
        path = PATCHES_FOLDER / f"{commit}.patch"
        if not path.is_file():
            raise BuildError(f"{path} is missing: the patch of {commit} ({cve})")
        if digest_of(path) != digest:
            raise BuildError(f"{path} is not the pinned patch of {commit} ({cve}): its SHA-256 is {digest_of(path)}")
        try:
            result = subprocess.run(
                ["/usr/bin/patch", "-p1", "--batch", "--forward", "-F0", "-d", str(folder), "-i", str(path)],
                capture_output=True, text=True, timeout=SHORT_SECONDS, check=False)
        except (OSError, subprocess.SubprocessError) as error:
            raise BuildError(f"patch could not run for {commit} ({cve}): {error}") from error
        if result.returncode != 0:
            raise BuildError(f"the patch of {commit} ({cve}) does not apply cleanly to FFmpeg {FFMPEG_VERSION}:\n"
                             f"{(result.stdout + result.stderr).strip()[-2000:]}")
        applied.append(commit)
    return applied


def unpacked_release(work, tarball, source=None):
    """The release unpacked in WORK/source/<key>/ffmpeg-<version> and patched, unpacking and
    patching it the first time. `source` (from `release_tarball`; found by the file's pin when
    not given) says the one folder the archive unpacks to, which is renamed to ffmpeg-<version>
    so that both sources give the same paths. Every member must be a file or folder inside that
    one folder: no absolute name, no "..", and no link or device, since the tarball is a
    download."""
    source = source or source_of(tarball)
    if source is None:
        raise BuildError(f"{tarball} is not FFmpeg {FFMPEG_VERSION}'s release: its SHA-256 is not a pin's")
    parent = unpacked_parent(work)
    folder = parent / f"ffmpeg-{FFMPEG_VERSION}"
    marker = unpacked_marker(work)
    if marker.is_file() and (folder / "configure").is_file():
        return folder
    parent.mkdir(parents=True, exist_ok=True)
    # One build unpacks at a time (the folder may be every checkout's), and the next to hold the
    # lock finds it done.
    with exclusive(parent.with_name(parent.name + ".lock")):
        if marker.is_file() and (folder / "configure").is_file():
            return folder
        prefix = source["folder"] + "/"
        with tarfile.open(tarball, "r:*") as archive:
            members = archive.getmembers()
            for member in members:
                name = member.name
                # The folder itself or something inside it, and nothing above it.
                if name.startswith("/") or ".." in Path(name).parts or not (name + "/").startswith(prefix):
                    raise BuildError(f"the release holds a file outside its folder: {name!r}")
                if not (member.isfile() or member.isdir()):
                    raise BuildError(f"the release holds something that is not a file or folder: {name!r}")
            for member in members:
                member.name = f"ffmpeg-{FFMPEG_VERSION}" + member.name[len(source["folder"]):]
            archive.extractall(parent, members=members)
        applied = apply_patches(folder)
        marker.write_text(f"{FFMPEG_SHA256}\n{source['name']}\n" + "".join(f"{commit}\n" for commit in applied),
                          encoding="utf-8")
    return folder


def check_release_notices(source):
    """Fails when the release's LICENSE.md or COPYING.LGPLv2.1 differ from the copies the apps
    ship (Vendor/package-licenses/FFmpeg): a new release that changed them needs new copies."""
    for name in RELEASE_NOTICES:
        shipped = NOTICES_FOLDER / name
        if not shipped.is_file():
            raise BuildError(f"{shipped} is missing: copy it from the release")
        if digest_of(shipped) != digest_of(source / name):
            raise BuildError(f"{shipped} differs from the release's {name}: copy the release's file over it")


# ---------------------------------------------------------------------------
# Building one platform
# ---------------------------------------------------------------------------

def build_key(platform, compiler):
    """The key of a build: the SHA-256 of everything that decides what it makes."""
    described = {
        "version": FFMPEG_VERSION, "sha256": FFMPEG_SHA256, "recipe": RECIPE, "platform": platform,
        "configure": configure_arguments(platform), "compiler": compiler, "patches": patches_digest(),
    }
    return hashlib.sha256(json.dumps(described, sort_keys=True).encode("utf-8")).hexdigest()


def enabled_components(configure_log):
    """What configure's summary says it enabled: its licence, and each "Enabled ..." list."""
    summary = {}
    licence = re.search(r"^License: (.+)$", configure_log, re.MULTILINE)
    summary["license"] = licence.group(1).strip() if licence else None
    # Each list is a heading line, "Enabled decoders:", then names in columns up to a blank line.
    for match in re.finditer(r"^Enabled ([a-z ]+):\n((?:.+\n)*?)\n", configure_log, re.MULTILINE):
        summary[match.group(1)] = sorted(match.group(2).split())
    return summary


def missing_components(summary):
    """The components asked for that configure's summary does not list, by kind; configure
    leaves out a component whose needs are unmet without failing."""
    asked = {"demuxers": DEMUXERS, "decoders": DECODERS, "parsers": PARSERS}
    return {kind: sorted(set(names) - set(summary.get(kind, []))) for kind, names in asked.items()
            if set(names) - set(summary.get(kind, []))}


def count_compiled(make_log):
    """How many files make compiled, by kind (CC for C, AS for assembly), from its output's
    lines, one for each file ("CC	libavcodec/wmadec.o")."""
    counts = {}
    for line in Path(make_log).read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.match(r"^\s*(CC|AS)\s+\S+", line)
        if match:
            counts[match.group(1)] = counts.get(match.group(1), 0) + 1
    return counts


def archive_members(path):
    """The members of the BSD archive (a static library) at `path`, as (name, bytes), in order,
    less its symbol table. A long name ("#1/<length>") is read from the start of the member."""
    data = Path(path).read_bytes()
    if not data.startswith(b"!<arch>\n"):
        raise BuildError(f"{path} is not an archive")
    members = []
    offset = 8
    while offset + 60 <= len(data):
        header = data[offset:offset + 60]
        if header[58:60] != b"`\n":
            raise BuildError(f"{path} has a damaged member header at byte {offset}")
        name = header[0:16].decode("ascii").rstrip()
        size = int(header[48:58].decode("ascii").strip())
        body = data[offset + 60:offset + 60 + size]
        if name.startswith("#1/"):
            length = int(name[3:])
            name = body[:length].rstrip(b"\0").decode("utf-8")
            body = body[length:]
        if not name.startswith("__.SYMDEF"):
            members.append((name, body))
        offset += 60 + size + (size % 2)
    return members


# The platforms LC_BUILD_VERSION names, by number.
MACHO_PLATFORMS = {1: "macOS", 2: "iOS", 7: "iOS simulator"}


def built_for(object_bytes):
    """The platform and minimum version an object file says it was built for, from its
    LC_BUILD_VERSION ("iOS 26.0"); None when it is no 64-bit Mach-O file or names none."""
    if len(object_bytes) < 32 or struct.unpack_from("<I", object_bytes, 0)[0] != 0xFEEDFACF:
        return None
    command_count = struct.unpack_from("<I", object_bytes, 16)[0]
    offset = 32
    for _ in range(command_count):
        if offset + 8 > len(object_bytes):
            return None
        command, command_size = struct.unpack_from("<II", object_bytes, offset)
        if command == 0x32:  # LC_BUILD_VERSION
            platform, minimum = struct.unpack_from("<II", object_bytes, offset + 8)
            name = MACHO_PLATFORMS.get(platform, f"platform {platform}")
            return f"{name} {minimum >> 16}.{(minimum >> 8) & 0xFF}"
        if command_size <= 0:
            return None
        offset += command_size
    return None


def merge_libraries(stage_lib, objects_folder, merged, platform):
    """Merges the four libraries in `stage_lib` into the one archive `merged`: every member is
    written to `objects_folder` under a name of its own ("avcodec-0012-utils.o"), checked to be
    built for `platform`, and handed to libtool. Returns the number of objects."""
    paths = []
    expected = PLATFORMS[platform]["built_for"]
    for library in LIBRARIES:
        short = library[3:]  # "avcodec"
        folder = objects_folder / short
        folder.mkdir(parents=True, exist_ok=True)
        for index, (name, body) in enumerate(archive_members(stage_lib / f"{library}.a")):
            found = built_for(body)
            if found != expected:
                raise BuildError(f"{library}.a({name}) was built for {found}, not {expected}")
            path = folder / f"{short}-{index:04d}-{Path(name).name}"
            path.write_bytes(body)
            paths.append(path)
    file_list = objects_folder / "objects.txt"
    file_list.write_text("".join(f"{path}\n" for path in paths), encoding="utf-8")
    temporary = merged.with_name(f".{merged.name}.merging")
    run_text(["xcrun", "libtool", "-static", "-no_warning_for_no_symbols", "-o", str(temporary),
              "-filelist", str(file_list)])
    os.replace(temporary, merged)
    return len(paths)


def forbidden_paths(work):
    """The folders of the building Mac that must not appear in what is built: the home folder,
    this checkout and the main one, the temporary folder (and its /private name), and the work
    folder; also any /Users/ path at all, which only a building Mac's folders begin with."""
    paths = {str(Path.home()), str(REPOSITORY), str(Path(work).resolve()), "/Users/"}
    if SHARED_DOWNLOADS is not None:
        # The main checkout, which the shared folder is in (build/ffmpeg/download).
        paths.add(str(SHARED_DOWNLOADS.parent.parent.parent))
    temporary = os.environ.get("TMPDIR") or tempfile.gettempdir()
    for folder in (temporary, os.path.realpath(temporary)):
        folder = folder.rstrip("/")
        if len(folder) > 1:
            paths.add(folder)
            paths.add(folder.replace("/private/", "/", 1))
    return sorted(path for path in paths if len(path) > 1)


def paths_found(strings_text, forbidden):
    """The lines of `strings_text` (what `strings` printed) that hold one of `forbidden`."""
    return [line for line in strings_text.splitlines() if any(path in line for path in forbidden)]


def check_no_mac_paths(files, work):
    """Fails when `strings` finds a folder of the building Mac in any of `files`."""
    forbidden = forbidden_paths(work)
    found = []
    for path in files:
        text = run_text(["xcrun", "strings", "-a", str(path)])
        found += [f"{Path(path).name}: {line[:160]}" for line in paths_found(text, forbidden)]
    if found:
        raise BuildError("the build holds folders of this Mac:\n" + "\n".join(found[:20]))


def build_header_text(key):
    """The header textmouth_ffmpeg_build.h: the release and the build's key, which the helper's
    session includes, so that a new build recompiles the session and relinks what links it."""
    return (
        "/* Written by Scripts/vendor/ffmpeg/build.py: the FFmpeg build TextMouth links. */\n"
        "#ifndef TEXTMOUTH_FFMPEG_BUILD_H\n"
        "#define TEXTMOUTH_FFMPEG_BUILD_H\n"
        f'#define TMFF_FFMPEG_RELEASE "{FFMPEG_VERSION}"\n'
        f'#define TMFF_FFMPEG_BUILD_KEY "{key[:16]}"\n'
        "#endif\n"
    )


def write_if_changed(path, text):
    """Writes `text` to `path` unless it already holds it, so its time changes only with it."""
    path = Path(path)
    if path.is_file() and path.read_text(encoding="utf-8") == text:
        return
    temporary = path.with_name(f".{path.name}.writing")
    temporary.write_text(text, encoding="utf-8")
    os.replace(temporary, path)


def published(work, platform):
    """The folder a platform's build is published in, which Xcode reads."""
    return work / platform


def is_published(work, platform, key):
    """Whether the build of `key` is already published for `platform`, whole."""
    folder = published(work, platform)
    key_file = folder / "key"
    return (key_file.is_file() and key_file.read_text(encoding="utf-8").strip() == key
            and (folder / "lib" / MERGED_LIBRARY).is_file() and (folder / "include" / BUILD_HEADER).is_file())


def build(platform, work, tarball=None, jobs=DEFAULT_JOBS):
    """Builds and publishes FFmpeg for `platform` in `work`, unless the same build is published.
    Returns the build's record."""
    work = Path(work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    compiler = compiler_version()
    key = build_key(platform, compiler)
    if is_published(work, platform, key):
        print(f"build.py: FFmpeg {FFMPEG_VERSION} for {platform} is up to date ({key[:12]})", flush=True)
        return json.loads((published(work, platform) / "build.json").read_text(encoding="utf-8"))
    started = time.monotonic()
    release, release_source = release_tarball(work, tarball)
    source = unpacked_release(work, release, release_source)
    check_release_notices(source)

    folder = work / f"build-{platform}-{key[:12]}"
    folder.mkdir(parents=True, exist_ok=True)
    (work / "bin").mkdir(exist_ok=True)
    wrapper = work / "bin" / COMPILER_WRAPPER
    write_if_changed(wrapper, compiler_wrapper_text())
    wrapper.chmod(0o755)
    environment = build_environment(work, platform)
    arguments = configure_arguments(platform)
    record = {
        "ffmpeg": FFMPEG_VERSION, "sha256": FFMPEG_SHA256, "platform": platform, "key": key,
        "compiler": compiler, "configure": shell_line(arguments), "jobs": jobs,
        "downloaded_from": release_source["name"], "patches": [commit for commit, _, _ in PATCHES],
    }
    print(f"build.py: configuring FFmpeg {FFMPEG_VERSION} for {platform}", flush=True)
    # configure is named by its path relative to the build folder: no absolute path is needed.
    configure = os.path.relpath(source / "configure", folder)
    wall, cpu = run_logged([configure, *arguments], folder / "configure.log", folder, environment, CONFIGURE_SECONDS)
    record["configure_seconds"] = {"wall": wall, "cpu": cpu}
    summary = enabled_components((folder / "configure.log").read_text(encoding="utf-8", errors="replace"))
    if summary.get("license") != "LGPL version 2.1 or later":
        raise BuildError(f"configure's licence is {summary.get('license')!r}, not LGPL version 2.1 or later")
    missing = missing_components(summary)
    if missing:
        raise BuildError(f"configure left out components the import needs: {missing}")
    print(f"build.py: making FFmpeg for {platform} with {jobs} jobs", flush=True)
    wall, cpu = run_logged(["make", f"-j{jobs}"], folder / "make.log", folder, environment, MAKE_SECONDS)
    record["make_seconds"] = {"wall": wall, "cpu": cpu}
    record["compiled"] = count_compiled(folder / "make.log")
    stage = folder / "stage"
    run_logged(["make", "install", f"DESTDIR={stage}"], folder / "install.log", folder, environment, SHORT_SECONDS)

    installed = stage / "usr" / "local"
    target = published(work, platform)
    (target / "lib").mkdir(parents=True, exist_ok=True)
    merged = target / "lib" / f".{MERGED_LIBRARY}.new"
    record["objects"] = merge_libraries(installed / "lib", folder / "objects", merged, platform)
    headers = sorted(path for path in (installed / "include").rglob("*.h"))
    check_no_mac_paths([merged, *headers], work)
    record["merged_library_bytes"] = merged.stat().st_size

    # Published last, the key after everything else, so a build stopped halfway is never taken
    # for a whole one.
    shutil.copytree(installed / "include", target / "include", dirs_exist_ok=True)
    write_if_changed(target / "include" / BUILD_HEADER, build_header_text(key))
    os.replace(merged, target / "lib" / MERGED_LIBRARY)
    record["total_seconds"] = round(time.monotonic() - started, 1)
    (target / "build.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (target / "key").write_text(key + "\n", encoding="utf-8")
    print(f"build.py: FFmpeg {FFMPEG_VERSION} for {platform} built in {record['total_seconds']} s "
          f"({record['compiled']}, {record['objects']} objects)", flush=True)
    return record


def build_locked(platform, work, tarball=None, jobs=DEFAULT_JOBS):
    """`build`, holding the work folder's lock, so two builds never write the same folder."""
    with exclusive(Path(work) / ".lock"):
        return build(platform, work, tarball, jobs)


# ---------------------------------------------------------------------------
# Xcode
# ---------------------------------------------------------------------------

def xcode_settings(environment):
    """The platform and work folder of an Xcode build phase, from the build settings Xcode
    exports to it: PLATFORM_NAME, OBJROOT, and ARCHS, which must be arm64 alone."""
    platform = environment.get("PLATFORM_NAME", "")
    if platform not in PLATFORMS:
        raise BuildError(f"FFmpeg is built for {', '.join(PLATFORMS)}, not {platform!r}")
    architectures = environment.get("ARCHS", "arm64").split()
    if architectures != ["arm64"]:
        raise BuildError(f"FFmpeg is built for arm64 alone, and this build asks for {' '.join(architectures)}")
    objects = environment.get("OBJROOT")
    if not objects:
        raise BuildError("Xcode gave no OBJROOT")
    return platform, Path(objects) / "FFmpeg"


# ---------------------------------------------------------------------------
# The notices
# ---------------------------------------------------------------------------

def patches_notice():
    """The lines of the README that say what TextMouth changed in the release, as the LGPL asks
    of a changed library: that it applies no patch ("unmodified"), or each patch by its upstream
    commit, the CVE it fixes, and the SHA-256 of the file kept in Scripts/vendor/ffmpeg/patches."""
    if not PATCHES:
        return ["TextMouth does not change the release: it is built as FFmpeg published it.", ""]
    lines = [
        f"TextMouth changes the release in one way: FFmpeg {FFMPEG_VERSION} with {len(PATCHES)} upstream patches. Each is a commit",
        "of FFmpeg's own development branch (https://github.com/FFmpeg/FFmpeg/commit/<commit>.patch), kept",
        "unchanged in Scripts/vendor/ffmpeg/patches/<commit>.patch, and applied, in this order, to the",
        "unpacked release by Scripts/vendor/ffmpeg/build.py before FFmpeg is built. Each fixes a CVE that the",
        f"National Vulnerability Database lists as open in {FFMPEG_VERSION}; the patches are dropped when a release includes them.",
        "",
    ]
    for commit, cve, digest in PATCHES:
        lines += [f"{cve}: {commit}", f"    SHA-256 of the patch file: {digest}"]
    return lines + [""]


def readme_text():
    """The README both apps ship in Licenses/FFmpeg: what FFmpeg is in TextMouth, its licence,
    the release and where it comes from, that it is unchanged, and each configure line."""
    lines = [
        "FFmpeg in TextMouth",
        "",
        "This software uses libraries from the FFmpeg project under the LGPLv2.1.",
        "",
        "TextMouth converts the audio of the formats macOS and iOS cannot read (Windows Media,",
        "Matroska and WebM, AVI, Flash video, RealMedia, Musepack, and Speex) with FFmpeg's",
        "libavformat, libavcodec, libswresample, and libavutil, linked statically, under the GNU",
        "Lesser General Public License, version 2.1 or later (COPYING.LGPLv2.1 and LICENSE.md, beside",
        "this file). No part of FFmpeg under the GPL is built: configure was not given --enable-gpl,",
        "--enable-nonfree, or --enable-version3, and its summary says \"License: LGPL version 2.1 or",
        "later\".",
        "",
        f"The release: FFmpeg {FFMPEG_VERSION}, from {FFMPEG_URL}",
        f"Its SHA-256: {FFMPEG_SHA256}",
        f"It is signed by FFmpeg's release key, fingerprint {SIGNING_KEY_FINGERPRINT}.",
        f"When ffmpeg.org cannot be reached, the build takes FFmpeg's own mirror's archive of the tag n{FFMPEG_VERSION}",
        f"instead, from {GITHUB_URL}",
        f"Its SHA-256: {GITHUB_SHA256}",
        "The two hold the same files, but for the release's VERSION file, which the tag's archive lacks, and",
        "git's own files (.gitattributes and .gitignore files), which the tarball lacks.",
        "",
        *patches_notice(),
        "TextMouth's own source, which is public under the MIT License, holds the script that",
        "downloads, checks, and builds this release (Scripts/vendor/ffmpeg/build.py), so anyone can",
        "build the app with a changed FFmpeg. The configure line of each platform, run by that",
        "script, where tmff-cc is Xcode's clang given the platform's SDK:",
        "",
    ]
    names = {"macosx": "The Mac (macOS 14.0, arm64)", "iphoneos": "The iPhone (iOS 26.0, arm64)",
             "iphonesimulator": "The iPhone simulator (iOS 26.0, arm64)"}
    for platform in PLATFORMS:
        lines += [f"{names[platform]}:", "", "configure " + shell_line(configure_arguments(platform)), ""]
    return "\n".join(lines)


def write_readme(check):
    """Writes the README of Licenses/FFmpeg, or with `check` reports whether it is current.
    Returns the exit status."""
    path = NOTICES_FOLDER / "README"
    wanted = readme_text()
    if check:
        current = path.read_text(encoding="utf-8") if path.is_file() else None
        if current != wanted:
            print(f"build.py: {path.relative_to(REPOSITORY)} is not what --readme writes; run it with --readme", flush=True)
            return 1
        print(f"build.py: {path.relative_to(REPOSITORY)} is current", flush=True)
        return 0
    NOTICES_FOLDER.mkdir(parents=True, exist_ok=True)
    write_if_changed(path, wanted)
    print(f"build.py: wrote {path.relative_to(REPOSITORY)}", flush=True)
    return 0


def check_signature(tarball, signature):
    """Checks `tarball` against its detached OpenPGP `signature` with gpg: the signature must be
    good and made by the pinned key (gpg's VALIDSIG line names its fingerprint). The key must be
    in gpg's keyring already. Returns the exit status."""
    result = subprocess.run(["gpg", "--status-fd", "1", "--verify", str(signature), str(tarball)],
                            capture_output=True, text=True, timeout=120, check=False)
    valid = re.search(r"^\[GNUPG:\] VALIDSIG ([0-9A-F]{40})", result.stdout, re.MULTILINE)
    if result.returncode == 0 and valid and valid.group(1) == SIGNING_KEY_FINGERPRINT:
        print(f"build.py: the signature is good, by {SIGNING_KEY_FINGERPRINT}", flush=True)
        return 0
    print(f"build.py: the signature is not good by {SIGNING_KEY_FINGERPRINT}:\n{result.stderr.strip()}", flush=True)
    return 1


# ---------------------------------------------------------------------------
# The command line
# ---------------------------------------------------------------------------

def main(argv):
    """Runs what the command line asks; returns the exit status."""
    parser = argparse.ArgumentParser(description="Builds the FFmpeg libraries TextMouth links.")
    parser.add_argument("--xcode", action="store_true")
    parser.add_argument("--platform", choices=sorted(PLATFORMS))
    parser.add_argument("--work")
    parser.add_argument("--tarball")
    parser.add_argument("--jobs", type=int, default=DEFAULT_JOBS)
    parser.add_argument("--print-configure", action="store_true")
    parser.add_argument("--readme", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--check-signature", action="store_true")
    parser.add_argument("--signature")
    options = parser.parse_args(argv)
    try:
        if options.readme:
            return write_readme(options.check)
        if options.check_signature:
            if not options.tarball or not options.signature:
                parser.error("--check-signature needs --tarball and --signature")
            return check_signature(options.tarball, options.signature)
        if options.print_configure:
            if not options.platform:
                parser.error("--print-configure needs --platform")
            print("configure " + shell_line(configure_arguments(options.platform)))
            return 0
        if options.xcode:
            platform, work = xcode_settings(os.environ)
        else:
            if not options.platform or not options.work:
                parser.error("a build needs --platform and --work, or --xcode")
            platform, work = options.platform, Path(options.work)
        if options.jobs < 1:
            parser.error("--jobs must be at least 1")
        build_locked(platform, work, options.tarball, options.jobs)
        return 0
    except BuildError as error:
        # Xcode shows a line that begins "error:" as the build's error.
        print(f"error: FFmpeg: {error}", file=sys.stderr, flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
