#!/usr/bin/env python3
"""build.py: builds minimal FFmpeg libraries and measures what they would add to TextMouth.

Research only (research/FFMPEG-MINIMAL-RESEARCH-2026-11-16.md). Nothing in the
app, project.yml, or the tests runs this script; it is kept as the record of
how the page's numbers were made.

Usage, from the repository (every build under the Mac's heavy-work lock):

    python3 -I Scripts/agents/run_locked.py ffmpeglib \
        python3 -I -B research/ffmpeg-minimal/build.py all --source SRC --work WORK [--only macos-a-small,...]
    python3 -I -B research/ffmpeg-minimal/build.py finish --source SRC --work WORK

    python3 -I -B research/ffmpeg-minimal/build.py build --set a --platform macos --variant small --source SRC --work WORK
    python3 -I -B research/ffmpeg-minimal/build.py measure --set a --platform macos --variant small --work WORK
    python3 -I -B research/ffmpeg-minimal/build.py decode --set a --variant small --work WORK
    python3 -I -B research/ffmpeg-minimal/build.py tree --set a --platform macos --variant small --source SRC --work WORK
    python3 -I -B research/ffmpeg-minimal/build.py xcframework --set a --variant small --work WORK
    python3 -I -B research/ffmpeg-minimal/build.py report --work WORK

SRC is an unpacked FFmpeg release (its signature checked first; see the page),
and WORK a scratch folder that holds the builds, the harnesses, the copies of
the test samples, and each step's JSON record.

What each step does:
- all: build, measure, and (on the Mac) decode, for every build of
  ALL_BUILDS or those --only names; the only heavy step, for the lock.
- finish: tree on each platform and xcframework, for the parity set; light.
- build: runs FFmpeg's configure with the set's components, then make and make
  install, timing each and counting the files compiled (WORK/builds/NAME).
- measure: compiles harness.c twice, without FFmpeg and with it, links each
  as the Release app links (dead code stripped, no exported symbols), strips
  and signs it, and records the difference, the linker's map by object file,
  and the functions the program imports from the system.
- decode: runs the Mac harness on copies of TestData/format-samples and
  compares its samples with those of the installed ffmpeg, which is run as a
  program with the same decoder forced.
- tree: lists the source files and headers the build compiled (from the
  compiler's dependency files), for a vendored, trimmed copy of the source.
- xcframework: makes an XCFramework of a set's Mac, iPhone, and iPhone
  simulator libraries, and measures it.
- report: prints every record as text.

The script deletes nothing: it writes into fixed folders, overwriting its own
files, and a build already made is kept and not made again.
"""
import argparse
import gzip
import json
import os
import re
import resource
import shutil
import struct
import subprocess
import sys
import tarfile
import time
from pathlib import Path

sys.dont_write_bytecode = True

# This folder (research/ffmpeg-minimal) and the repository above it.
HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parent.parent

# The test samples the decode step copies, from TestData/format-samples.
SAMPLES_FOLDER = REPOSITORY / "TestData" / "format-samples"

# The ffmpeg a Mac has from Homebrew, run only as a program, for the
# reference decode (TextMouth's import runs the same one today).
INSTALLED_FFMPEG = Path("/opt/homebrew/bin/ffmpeg")

# How many compile jobs make runs at once. The Mac has 8 cores and 8 GB of
# memory, and other agents' sessions share it, so half.
JOBS = 4

# The limits of each step's commands, in seconds.
CONFIGURE_SECONDS = 900
MAKE_SECONDS = 2400
SHORT_SECONDS = 300

# ---------------------------------------------------------------------------
# The sets of components
# ---------------------------------------------------------------------------

# The demuxers TextMouth's import forces today (FFmpegContainer.demuxer):
# ASF (WMA, WMV), Matroska and WebM, Flash video, AVI, RealMedia, Musepack
# stream versions 7 and 8, and Ogg (Speex, and an .spx holding another codec).
PARITY_DEMUXERS = ["asf", "matroska", "flv", "avi", "rm", "mpc", "mpc8", "ogg"]

# The five WMA decoders: WMA 1, WMA 2, Pro, Lossless, and Voice.
WMA_DECODERS = ["wmav1", "wmav2", "wmapro", "wmalossless", "wmavoice"]

# The decoders for what those containers carry, as TextMouth's code and tests
# name it (FFmpegAudioConverter.isLossless, FFmpegImportPlanTests, the
# samples), plus the common codecs of each container:
# - Speex, and Musepack 7 and 8;
# - RealAudio: Cook, ACELP.net (sipr), ATRAC3, RealAudio Lossless, 14.4, 28.8;
# - the lossy codecs of Matroska, AVI, Flash, and RealAudio 10: AAC, MP3, MP2,
#   AC-3, E-AC-3, Opus, Vorbis, DTS;
# - the lossless ones: FLAC, ALAC, TrueHD, MLP, and TTA, WavPack, and Monkey's
#   Audio inside Matroska (TextMouth reads their own files itself);
# - PCM of every common layout, A-law, and mu-law;
# - what only video files carry: Microsoft and IMA ADPCM, Flash ADPCM,
#   Nellymoser, and Microsoft GSM.
OTHER_PARITY_DECODERS = [
    "speex", "mpc7", "mpc8",
    "cook", "sipr", "atrac3", "ralf", "ra_144", "ra_288",
    "aac", "mp3float", "mp2float", "ac3", "eac3", "opus", "vorbis", "dca",
    "flac", "alac", "truehd", "mlp", "tta", "wavpack", "ape",
    "pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be",
    "pcm_f32le", "pcm_f32be", "pcm_f64le", "pcm_f64be", "pcm_u8", "pcm_s8", "pcm_alaw", "pcm_mulaw",
    "adpcm_ms", "adpcm_ima_wav", "adpcm_swf", "nellymoser", "gsm_ms",
]

# The parsers of those codecs, which split a container's packets into frames.
PARITY_PARSERS = ["aac", "ac3", "cook", "dca", "flac", "gsm", "mlp", "mpegaudio", "opus", "sipr", "vorbis"]

# What only the video containers (AVI and Flash video) bring: their demuxers,
# and the codecs no audio container of the set carries.
VIDEO_ONLY_DEMUXERS = ["avi", "flv"]
VIDEO_ONLY_DECODERS = ["adpcm_ms", "adpcm_ima_wav", "adpcm_swf", "nellymoser", "gsm_ms"]
VIDEO_ONLY_PARSERS = ["gsm"]


def without(items, removed):
    """`items` in order, less those in `removed`."""
    return [item for item in items if item not in removed]


SETS = {
    "a": {
        "title": "Parity: every container and codec the installed-ffmpeg path converts",
        "demuxers": PARITY_DEMUXERS,
        "decoders": WMA_DECODERS + OTHER_PARITY_DECODERS,
        "parsers": PARITY_PARSERS,
    },
    "b": {
        "title": "WMA only: the ASF demuxer and the five WMA decoders",
        "demuxers": ["asf"],
        "decoders": WMA_DECODERS,
        "parsers": [],
    },
    "c": {
        "title": "Parity without the video containers (AVI, Flash video) and the codecs only they carry",
        "demuxers": without(PARITY_DEMUXERS, VIDEO_ONLY_DEMUXERS),
        "decoders": without(WMA_DECODERS + OTHER_PARITY_DECODERS, VIDEO_ONLY_DECODERS),
        "parsers": without(PARITY_PARSERS, VIDEO_ONLY_PARSERS),
    },
    "d": {
        "title": "WMA and WebM: ASF with the five WMA decoders, and Matroska with Opus and Vorbis",
        "demuxers": ["asf", "matroska"],
        "decoders": WMA_DECODERS + ["opus", "vorbis"],
        "parsers": ["opus", "vorbis"],
    },
}

# The variants of each build: optimized for speed (FFmpeg's default, -O3),
# for size (--enable-small, -Os and FFmpeg's own smaller code paths), and for
# size with link-time optimization.
VARIANTS = {
    "speed": [],
    "small": ["--enable-small"],
    "small-lto": ["--enable-small", "--enable-lto"],
}

# The platforms: each one's SDK, and the target clang compiles for. The Mac's
# deployment target is the app's, 14.0; the iPhone's is 26.0.
PLATFORMS = {
    "macos": {"sdk": "macosx", "target": "arm64-apple-macos14.0", "cross": False},
    "ios": {"sdk": "iphoneos", "target": "arm64-apple-ios26.0", "cross": True},
    "iossim": {"sdk": "iphonesimulator", "target": "arm64-apple-ios26.0-simulator", "cross": True},
}

# Every build `all` makes, in order: (set, platform, variant).
ALL_BUILDS = [
    ("a", "macos", "small"), ("a", "macos", "speed"),
    ("b", "macos", "small"), ("b", "macos", "speed"),
    ("c", "macos", "small"), ("c", "macos", "speed"),
    ("d", "macos", "small"),
    ("a", "ios", "small"), ("a", "iossim", "small"),
    ("a", "macos", "small-lto"),
    ("b", "ios", "small"), ("d", "ios", "small"), ("d", "iossim", "small"),
]

# The test samples, by their path under TestData/format-samples, and the
# demuxer TextMouth's sniff forces for each.
SAMPLES = [
    ("wma/tones.wma", "asf"),
    ("wma/tones-wma1.wma", "asf"),
    ("wma/three-tones-chapters.wma", "asf"),
    ("wmv/tones.wmv", "asf"),
    ("avi/tones-mp3.avi", "avi"),
    ("flv/tones-aac.flv", "flv"),
    ("mkv/three-tones-flac.mkv", "matroska"),
    ("mka/tones-5.1-ac3.mka", "matroska"),
    ("mka/tones-2tracks.mka", "matroska"),
    ("webm/tones-opus.webm", "matroska"),
    ("webm/tones-vorbis.weba", "matroska"),
    ("spx/tones.spx", "ogg"),
    ("rm/tones.ra", "rm"),
]

# Functions whose import would mean a child process, loaded code, or another
# process's memory: none of them may appear in what an iPhone build imports.
FORBIDDEN_ON_IOS = [
    "_fork", "_vfork", "_execve", "_execv", "_execvp", "_execvP", "_execl", "_execlp", "_execle",
    "_posix_spawn", "_posix_spawnp", "_system", "_popen", "_dlopen", "_dlsym", "_ptrace", "_task_for_pid",
]

# Functions of Apple's required-reason APIs (privacy manifests), by category.
REQUIRED_REASON = {
    "file timestamp": ["_stat", "_fstat", "_lstat", "_fstatat", "_getattrlist", "_fgetattrlist", "_getattrlistbulk"],
    "system boot time": ["_mach_absolute_time"],
    "disk space": ["_statfs", "_fstatfs", "_statvfs", "_fstatvfs"],
}


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def build_name(set_name, platform, variant):
    """The folder name of one build: platform, set, and variant."""
    return f"{platform}-{set_name}-{variant}"


def build_folder(work, set_name, platform, variant):
    """The folder one build is made in, under WORK/builds."""
    return Path(work) / "builds" / build_name(set_name, platform, variant)


def write_json(path, value):
    """Writes `value` to `path` as indented JSON, replacing what was there."""
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def read_json(path):
    """The JSON value in `path`, or None when there is no such file."""
    path = Path(path)
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def sdk_path(sdk):
    """The path of Xcode's SDK named `sdk` (macosx, iphoneos, iphonesimulator)."""
    return run_text(["xcrun", "--sdk", sdk, "--show-sdk-path"]).strip()


def tool_path(name):
    """The path of the Xcode tool `name` (clang, strip, nm, ...)."""
    return run_text(["xcrun", "-f", name]).strip()


def run_text(command, cwd=None, seconds=SHORT_SECONDS):
    """Runs `command` and returns its standard output; raises on a failure."""
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, timeout=seconds, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"{command[0]} failed ({result.returncode}): {result.stderr.strip()[-2000:]}")
    return result.stdout


def run_logged(command, log_path, cwd=None, seconds=SHORT_SECONDS):
    """Runs `command` with its output (both streams) written to `log_path`.

    Returns the exit status, the wall-clock seconds, and the processor seconds
    (user and system) of the command and every process it started and waited
    for, which a parallel make's compiles are.
    """
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    started = time.monotonic()
    with open(log_path, "w", encoding="utf-8") as log:
        try:
            status = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=seconds, check=False).returncode
        except subprocess.TimeoutExpired:
            log.write(f"\nbuild.py: stopped after {seconds} seconds\n")
            status = -1
    wall = time.monotonic() - started
    after = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
    return status, round(wall, 1), round(cpu, 1)


def tail(path, lines=40):
    """The last `lines` lines of the text file at `path`."""
    text = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    return "\n".join(text[-lines:])


# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------

# The decoders that need libswresample: FFmpeg 9.0.2's configure disables the
# Opus decoder without it ("Disabled opus_decoder because not all dependencies
# are satisfied: swresample").
NEEDS_SWRESAMPLE = {"opus"}


def needs_swresample(set_name):
    """Whether the set has a decoder that needs libswresample."""
    return bool(NEEDS_SWRESAMPLE & set(SETS[set_name]["decoders"]))


def configure_arguments(set_name, platform, variant, source, prefix):
    """FFmpeg's configure line for one build, as a list of arguments.

    The base is the brief's: nothing enabled but what is named, nothing
    detected, no network, no programs, no documentation, and static libraries
    only. libavdevice, libswscale, and libavfilter are left out, and
    libswresample too unless a decoder of the set needs it: the decode path
    needs none of them otherwise (TextMouth's own code would hand the samples
    to Apple's converter and encoder). No protocol is enabled, since the
    program reads the file through its own callbacks.
    """
    components = SETS[set_name]
    target = PLATFORMS[platform]
    sysroot = sdk_path(target["sdk"])
    # The target and the SDK are part of the compiler's command, which
    # configure also uses to assemble FFmpeg's assembly files and to link, so
    # every object is built for the platform (build() checks each one).
    compiler = f"{tool_path('clang')} --target={target['target']} -isysroot {sysroot}"
    arguments = [
        str(Path(source) / "configure"),
        f"--prefix={prefix}",
        "--disable-everything", "--disable-autodetect", "--disable-network",
        "--disable-programs", "--disable-doc",
        "--disable-avdevice", "--disable-swscale", "--disable-avfilter",
    ]
    if not needs_swresample(set_name):
        arguments.append("--disable-swresample")
    arguments += [
        "--enable-static", "--disable-shared", "--disable-debug",
        f"--cc={compiler}",
        f"--as={compiler}",
        f"--sysroot={sysroot}",
    ]
    if target["cross"]:
        arguments += ["--enable-cross-compile", "--target-os=darwin", "--arch=aarch64"]
    arguments += VARIANTS[variant]
    arguments += [f"--enable-demuxer={name}" for name in components["demuxers"]]
    arguments += [f"--enable-decoder={name}" for name in components["decoders"]]
    arguments += [f"--enable-parser={name}" for name in components["parsers"]]
    return arguments


def parse_configure_summary(text):
    """What configure's summary says: the licence, threading, and each
    'Enabled ...' list (decoders, demuxers, parsers, bsfs, protocols, ...)."""
    summary = {}
    licence = re.search(r"^License: (.+)$", text, re.MULTILINE)
    summary["license"] = licence.group(1).strip() if licence else None
    threading = re.search(r"^threading support\s+(.+)$", text, re.MULTILINE)
    summary["threading"] = threading.group(1).strip() if threading else None
    # Each list is a heading line, "Enabled decoders:", then names in columns
    # up to the next blank line.
    for match in re.finditer(r"^(Enabled [a-z ]+):\n((?:.+\n)*?)\n", text, re.MULTILINE):
        summary[match.group(1)] = sorted(match.group(2).split())
    return summary


def count_compiled(make_log):
    """How many files make compiled, by kind (CC for C, AS for assembly), from
    its quiet output, one line per file: "CC  libavcodec/wmadec.o"."""
    counts = {}
    for line in Path(make_log).read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.match(r"^\s*(CC|AS|CXX|OBJCC|HOSTCC)\s+\S+", line)
        if match:
            counts[match.group(1)] = counts.get(match.group(1), 0) + 1
    return counts


def object_files(folder):
    """Every .o file under `folder`, relative to it, sorted."""
    return sorted(str(path.relative_to(folder)) for path in Path(folder).rglob("*.o"))


# The platforms LC_BUILD_VERSION names, by number.
MACHO_PLATFORMS = {1: "macOS", 2: "iOS", 7: "iOS simulator"}


def object_build_version(path):
    """The platform and minimum version an object file was built for, from its
    LC_BUILD_VERSION ("iOS 26.0"); "LLVM bitcode" for a link-time-optimized
    object; None when it names neither."""
    data = Path(path).read_bytes()
    if data[:4] == b"\xde\xc0\x17\x0b" or data[:2] == b"BC":
        return "LLVM bitcode"
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        return None
    command_count = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    for _ in range(command_count):
        command, command_size = struct.unpack_from("<II", data, offset)
        if command == 0x32:  # LC_BUILD_VERSION
            platform, minimum = struct.unpack_from("<II", data, offset + 8)
            name = MACHO_PLATFORMS.get(platform, f"platform {platform}")
            return f"{name} {minimum >> 16}.{(minimum >> 8) & 0xFF}"
        offset += command_size
    return None


def build_versions(folder, objects):
    """How many of `objects` (paths relative to `folder`) were built for each
    platform and minimum version: one entry when the build is right."""
    counts = {}
    for name in objects:
        version = object_build_version(Path(folder) / name) or "none"
        counts[version] = counts.get(version, 0) + 1
    return counts


def build(set_name, platform, variant, source, work):
    """Configures, makes, and installs one build, and records it in build.json.
    A build already recorded is kept as it is."""
    folder = build_folder(work, set_name, platform, variant)
    record_path = folder / "build.json"
    if record_path.exists():
        print(f"build: {folder.name} is already built")
        return read_json(record_path)
    folder.mkdir(parents=True, exist_ok=True)
    prefix = folder / "install"
    arguments = configure_arguments(set_name, platform, variant, source, prefix)
    record = {"name": folder.name, "set": set_name, "platform": platform, "variant": variant,
              "configure": arguments[1:], "jobs": JOBS}
    print(f"build: configuring {folder.name}", flush=True)
    status, wall, cpu = run_logged(arguments, folder / "configure.log", cwd=folder, seconds=CONFIGURE_SECONDS)
    record["configure_seconds"] = {"wall": wall, "cpu": cpu, "status": status}
    if status != 0:
        record["error"] = "configure failed: " + tail(folder / "configure.log")
        write_json(folder / "build-failed.json", record)
        return record
    record["summary"] = parse_configure_summary((folder / "configure.log").read_text(encoding="utf-8", errors="replace"))
    # configure drops a component whose needs are unmet without failing, so
    # each one asked for must be among those its summary says it enabled.
    record["components_missing"] = {
        kind: sorted(set(SETS[set_name][kind]) - set(record["summary"].get(f"Enabled {kind}", [])))
        for kind in ("demuxers", "decoders", "parsers")
    }
    config_mak = (folder / "ffbuild" / "config.mak").read_text(encoding="utf-8", errors="replace")
    record["flags"] = {key: value.strip() for key, value in re.findall(r"^(CFLAGS|CPPFLAGS|ASFLAGS|LDFLAGS|EXTRALIBS[-A-Za-z]*)=(.*)$", config_mak, re.MULTILINE)}
    print(f"build: making {folder.name}", flush=True)
    status, wall, cpu = run_logged(["make", f"-j{JOBS}"], folder / "make.log", cwd=folder, seconds=MAKE_SECONDS)
    record["make_seconds"] = {"wall": wall, "cpu": cpu, "status": status}
    if status != 0:
        record["error"] = "make failed: " + tail(folder / "make.log")
        write_json(folder / "build-failed.json", record)
        return record
    status, wall, cpu = run_logged(["make", "install"], folder / "install.log", cwd=folder, seconds=SHORT_SECONDS)
    record["install_seconds"] = {"wall": wall, "cpu": cpu, "status": status}
    if status != 0:
        record["error"] = "make install failed: " + tail(folder / "install.log")
        write_json(folder / "build-failed.json", record)
        return record
    record["compiled"] = count_compiled(folder / "make.log")
    objects = [name for name in object_files(folder) if not name.startswith("install/")]
    record["object_files"] = len(objects)
    record["object_build_versions"] = build_versions(folder, objects)
    record["object_files_by_library"] = {}
    for name in objects:
        library = name.split("/")[0]
        record["object_files_by_library"][library] = record["object_files_by_library"].get(library, 0) + 1
    record["static_library_bytes"] = {
        path.name: path.stat().st_size for path in sorted((prefix / "lib").glob("*.a"))
    }
    write_json(record_path, record)
    print(f"build: {folder.name}: {record['compiled']} files in {record['make_seconds']['wall']} s", flush=True)
    return record


# ---------------------------------------------------------------------------
# measure
# ---------------------------------------------------------------------------

def macho_layout(path):
    """The size of the Mach-O file at `path`, its segments' file sizes, its
    sections' sizes (zero-fill sections, which take no file bytes, apart),
    and its code signature's size. A 64-bit, single-architecture file only."""
    data = Path(path).read_bytes()
    magic, _cpu, _subtype, _filetype, command_count, _commands_size, _flags, _reserved = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != 0xFEEDFACF:
        raise ValueError(f"{path} is not a 64-bit Mach-O file")
    layout = {"file_bytes": len(data), "segments": {}, "sections": {}, "zerofill_sections": {}, "signature_bytes": 0}
    offset = 32
    for _ in range(command_count):
        command, command_size = struct.unpack_from("<II", data, offset)
        if command == 0x19:  # LC_SEGMENT_64
            name = data[offset + 8:offset + 24].rstrip(b"\0").decode()
            _vmaddr, vmsize, _fileoff, filesize, _maxprot, _initprot, section_count, _flags = struct.unpack_from("<QQQQiiII", data, offset + 24)
            layout["segments"][name] = {"vmsize": vmsize, "filesize": filesize}
            for index in range(section_count):
                start = offset + 72 + index * 80
                section = data[start:start + 16].rstrip(b"\0").decode()
                segment = data[start + 16:start + 32].rstrip(b"\0").decode()
                _addr, size = struct.unpack_from("<QQ", data, start + 32)
                (section_flags,) = struct.unpack_from("<I", data, start + 64)
                # S_ZEROFILL, S_GB_ZEROFILL, and S_THREAD_LOCAL_ZEROFILL take no file bytes.
                kind = "zerofill_sections" if section_flags & 0xFF in (0x1, 0xC, 0x12) else "sections"
                layout[kind][f"{segment},{section}"] = size
        elif command == 0x1D:  # LC_CODE_SIGNATURE
            _dataoff, datasize = struct.unpack_from("<II", data, offset + 8)
            layout["signature_bytes"] = datasize
        offset += command_size
    layout["section_bytes"] = sum(layout["sections"].values())
    return layout


# The sections whose bytes take memory but no bytes of the file.
ZEROFILL_SECTIONS = {"__bss", "__common", "__thread_bss"}

# The components the linked bytes are grouped into, each a pattern on an
# object file's name in its library ("libavcodec.a(wmaprodec.o)"), tried in
# order; an object no pattern matches counts as its library's core. The names
# are those the build printed; no source was read to make them.
COMPONENT_PATTERNS = [
    ("WMA decoders", r"^libavcodec\.a\(wma"),
    ("ASF demuxer", r"^libavformat\.a\(asf"),
    ("Matroska and WebM demuxer", r"^libavformat\.a\((matroska|webm)"),
    ("Ogg demuxer", r"^libavformat\.a\(ogg"),
    ("Flash video demuxer", r"^libavformat\.a\(flv"),
    # avidec only: avio.o and aviobuf.o are libavformat's own reading code.
    ("AVI demuxer", r"^libavformat\.a\(avidec"),
    ("RealMedia demuxer", r"^libavformat\.a\(rm"),
    ("Musepack demuxers", r"^libavformat\.a\(mpc"),
    ("RIFF and WAVE headers (shared by ASF, AVI, Matroska)", r"^libavformat\.a\(riff"),
    ("Speex decoder", r"^libavcodec\.a\(speex"),
    ("Musepack decoders", r"^libavcodec\.a\(mpc"),
    # The speech codecs' shared tools serve WMA Voice as well as ACELP.net.
    ("Speech-codec tools (WMA Voice, ACELP.net)", r"^libavcodec\.a\((acelp|celp|lsp)"),
    ("RealAudio decoders", r"^libavcodec\.a\((cook|sipr|atrac|ralf|ra144|ra288)"),
    # aactab.o counts here: the linker keeps only the tables a build uses,
    # which with the AAC decoder are its own (31 KB), and without it 606
    # bytes that other decoders share.
    ("AAC decoder", r"^libavcodec\.a\(aac|^libavcodec\.a\(sbr|^libavcodec\.a\(psdata|^libavcodec\.a\(cbrt"),
    ("MP3 and MP2 decoders", r"^libavcodec\.a\(mpegaudio|^libavcodec\.a\(mpa|^libavcodec\.a\(dct32"),
    ("AC-3 and E-AC-3 decoders", r"^libavcodec\.a\((ac3|eac3)"),
    ("DTS decoder", r"^libavcodec\.a\(dca|^libavcodec\.a\(dolby_e|^libavcodec\.a\(synth_filter"),
    ("Opus decoder", r"^libavcodec\.a\(opus|^libavcodec\.a\(celt|^libavcodec\.a\(silk"),
    ("Vorbis decoder", r"^libavcodec\.a\(vorbis"),
    ("FLAC decoder", r"^libavcodec\.a\(flac"),
    ("ALAC decoder", r"^libavcodec\.a\(alac"),
    ("TrueHD and MLP decoders", r"^libavcodec\.a\(mlp|^libavcodec\.a\(truehd"),
    ("TTA, WavPack, and Monkey's Audio decoders", r"^libavcodec\.a\((tta|wavpack|ape)"),
    ("PCM decoders", r"^libavcodec\.a\(pcm"),
    ("ADPCM, Nellymoser, and GSM decoders", r"^libavcodec\.a\((adpcm|nelly|gsm|msgsm)"),
    ("libavcodec's core and shared parts", r"^libavcodec\.a\("),
    ("libavformat's core", r"^libavformat\.a\("),
    ("libswresample (for Opus)", r"^libswresample\.a\("),
    ("libavutil", r"^libavutil\.a\("),
]


def by_component(by_object):
    """The linked bytes of `by_object` (link_map_by_object's result) summed by
    COMPONENT_PATTERNS, each with the object files it holds; objects outside
    FFmpeg's libraries (the harness, the system's stubs) are left out."""
    patterns = [(name, re.compile(pattern)) for name, pattern in COMPONENT_PATTERNS]
    components = {}
    for name, sizes in by_object.items():
        component = next((label for label, pattern in patterns if pattern.search(name)), None)
        if component is None:
            continue
        entry = components.setdefault(component, {"file": 0, "zerofill": 0, "objects": []})
        entry["file"] += sizes["file"]
        entry["zerofill"] += sizes["zerofill"]
        entry["objects"].append(name.split("(")[1].rstrip(")"))
    return dict(sorted(components.items(), key=lambda item: -item[1]["file"]))


def link_map_by_object(map_path):
    """The bytes each object file keeps in the linked program, from the
    linker's map (-map): every live symbol's size, summed by the file it came
    from, apart for the bytes in the file ("file") and those of zero-fill
    sections, which take memory only ("zerofill"). Files are named
    "libavcodec.a(wmadec.o)", or by their own name. Sorted by file bytes."""
    text = Path(map_path).read_text(encoding="utf-8", errors="replace")
    files, sections, totals = {}, [], {}
    part = None
    for line in text.splitlines():
        if line.startswith("# Object files:"):
            part = "objects"
            continue
        if line.startswith("# Sections:"):
            part = "sections"
            continue
        if line.startswith("# Symbols:"):
            part = "symbols"
            continue
        if line.startswith("# Dead Stripped Symbols:"):
            break
        if part == "objects":
            match = re.match(r"^\[\s*(\d+)\]\s+(.*)$", line)
            if match:
                path = match.group(2).strip()
                member = re.search(r"/(lib\w+\.a)(?:\[\d+\])?\((.+)\)$", path)
                files[int(match.group(1))] = f"{member.group(1)}({member.group(2)})" if member else Path(path).name
        elif part == "sections":
            match = re.match(r"^0x([0-9A-Fa-f]+)\s+0x([0-9A-Fa-f]+)\s+(\S+)\s+(\S+)\s*$", line)
            if match:
                start, size = int(match.group(1), 16), int(match.group(2), 16)
                sections.append((start, start + size, match.group(4) in ZEROFILL_SECTIONS))
        elif part == "symbols":
            match = re.match(r"^0x([0-9A-Fa-f]+)\s+0x([0-9A-Fa-f]+)\s+\[\s*(\d+)\]\s", line)
            if match:
                address, size = int(match.group(1), 16), int(match.group(2), 16)
                zerofill = any(start <= address < end and empty for start, end, empty in sections)
                entry = totals.setdefault(files.get(int(match.group(3)), "?"), {"file": 0, "zerofill": 0})
                entry["zerofill" if zerofill else "file"] += size
    return dict(sorted(totals.items(), key=lambda item: -item[1]["file"]))


def imported_symbols(binary):
    """The symbols the linked program `binary` imports (nm -u), sorted."""
    return sorted(set(run_text([tool_path("nm"), "-u", str(binary)]).split()))


def library_undefined_symbols(libraries):
    """Every symbol the static `libraries` leave undefined that none of them
    defines: what the whole libraries would need from the system."""
    defined, undefined = set(), set()
    for library in libraries:
        for line in run_text([tool_path("nm"), "-g", str(library)]).splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] == "U":
                undefined.add(parts[1])
            elif len(parts) == 3 and parts[1] not in ("U",):
                defined.add(parts[2])
    return sorted(undefined - defined)


def compile_and_link(platform, output, defines, include_folder, libraries, map_path):
    """Compiles harness.c for `platform` and links it as the Release app links:
    -Os, dead code stripped, no exported symbols, then stripped of every symbol
    and signed ad hoc (the linker signs arm64 programs, and strip changes the
    file). Returns the program's path."""
    target = PLATFORMS[platform]
    sysroot = sdk_path(target["sdk"])
    clang = tool_path("clang")
    object_path = output.with_suffix(".o")
    compile_command = [clang, "-target", target["target"], "-isysroot", sysroot, "-Os", "-std=c11",
                       "-Wall", "-Wextra", "-c", str(HERE / "harness.c"), "-o", str(object_path)]
    compile_command += [f"-D{define}" for define in defines]
    if include_folder:
        compile_command += ["-I", str(include_folder)]
    run_text(compile_command)
    link_command = [clang, "-target", target["target"], "-isysroot", sysroot, str(object_path)]
    link_command += [str(library) for library in libraries]
    link_command += ["-Wl,-dead_strip", "-Wl,-no_exported_symbols", f"-Wl,-map,{map_path}", "-o", str(output)]
    run_text(link_command)
    run_text([tool_path("strip"), str(output)])
    run_text(["codesign", "--force", "--sign", "-", str(output)])
    return output


def built_libraries(prefix):
    """The static libraries a build installed under `prefix`, in the order a
    static link needs, each before the ones it calls: libavformat, libavcodec,
    libswresample (when the set needed it), libavutil."""
    names = ("libavformat.a", "libavcodec.a", "libswresample.a", "libavutil.a")
    return [Path(prefix) / "lib" / name for name in names if (Path(prefix) / "lib" / name).exists()]


def measure(set_name, platform, variant, work):
    """Links the harness with and without one build's libraries, and records in
    measure.json what the libraries add, by size, by object file, and by the
    functions imported from the system."""
    folder = build_folder(work, set_name, platform, variant)
    built = read_json(folder / "build.json")
    if not built:
        print(f"measure: {folder.name} was not built", flush=True)
        return None
    harness_folder = folder / "harness"
    harness_folder.mkdir(exist_ok=True)
    prefix = folder / "install"
    libraries = built_libraries(prefix)
    baseline = compile_and_link(platform, harness_folder / "baseline", ["HARNESS_BASELINE"], None, [],
                                harness_folder / "baseline.map")
    full = compile_and_link(platform, harness_folder / "harness", [], prefix / "include", libraries,
                            harness_folder / "harness.map")
    baseline_layout, full_layout = macho_layout(baseline), macho_layout(full)
    imports = imported_symbols(full)
    whole_library_needs = library_undefined_symbols(libraries)
    by_object = link_map_by_object(harness_folder / "harness.map")
    record = {
        "name": folder.name,
        "baseline": baseline_layout,
        "harness": full_layout,
        "added_file_bytes": full_layout["file_bytes"] - baseline_layout["file_bytes"],
        "added_section_bytes": full_layout["section_bytes"] - baseline_layout["section_bytes"],
        "linked_bytes_by_object": by_object,
        "linked_bytes_by_component": by_component(by_object),
        "linked_bytes_by_library": {},
        "imports": imports,
        "dylibs": run_text(["otool", "-L", str(full)]).splitlines()[1:],
        "forbidden_on_ios_imported": [name for name in FORBIDDEN_ON_IOS if name in imports],
        "forbidden_on_ios_in_whole_libraries": [name for name in FORBIDDEN_ON_IOS if name in whole_library_needs],
        "required_reason_imported": {
            category: [name for name in names if name in imports] for category, names in REQUIRED_REASON.items()
        },
        "whole_libraries_need": whole_library_needs,
    }
    for name, sizes in by_object.items():
        library = name.split("(")[0] if "(" in name else "the harness, the system, and the linker"
        totals = record["linked_bytes_by_library"].setdefault(library, {"file": 0, "zerofill": 0})
        totals["file"] += sizes["file"]
        totals["zerofill"] += sizes["zerofill"]
    write_json(folder / "measure.json", record)
    print(f"measure: {folder.name}: adds {record['added_file_bytes']:,} bytes", flush=True)
    return record


# ---------------------------------------------------------------------------
# decode
# ---------------------------------------------------------------------------

# The installed ffmpeg's raw output for each decoded sample format, packed:
# its PCM encoder and its raw muxer. A planar format becomes the packed one
# of the same type, an exact copy of the samples.
RAW_FORMATS = {
    "u8": ("pcm_u8", "u8"), "u8p": ("pcm_u8", "u8"),
    "s16": ("pcm_s16le", "s16le"), "s16p": ("pcm_s16le", "s16le"),
    "s32": ("pcm_s32le", "s32le"), "s32p": ("pcm_s32le", "s32le"),
    "flt": ("pcm_f32le", "f32le"), "fltp": ("pcm_f32le", "f32le"),
    "dbl": ("pcm_f64le", "f64le"), "dblp": ("pcm_f64le", "f64le"),
}

# The struct format of one sample of each raw output, for comparing values.
SAMPLE_STRUCT = {"u8": "B", "s16le": "h", "s32le": "i", "f32le": "f", "f64le": "d"}


# The most whole frames (a sample of every channel) one decode may lead the
# other by: decoders differ by version in whether they drop their start-up
# delay (AC-3's is 256 samples a channel).
MAXIMUM_LEAD_FRAMES = 4096


def compare_samples(ours, theirs, raw, channels):
    """How the harness's samples `ours` compare with the installed ffmpeg's
    `theirs`, both raw bytes of the format `raw` with `channels` interleaved.

    Identical; or identical once one of them is shifted by a whole number of
    frames, at most MAXIMUM_LEAD_FRAMES (the lead, in frames, and the largest
    value of the samples it skips); or else how many samples each has and the
    largest difference over the samples both have."""
    code = SAMPLE_STRUCT[raw]
    width = struct.calcsize(code)
    if ours == theirs:
        return {"identical": True, "samples": len(ours) // width}
    first = struct.unpack(f"<{len(ours) // width}{code}", ours[:len(ours) // width * width])
    second = struct.unpack(f"<{len(theirs) // width}{code}", theirs[:len(theirs) // width * width])
    step = max(channels, 1)
    for frames in range(1, MAXIMUM_LEAD_FRAMES + 1):
        shift = frames * step
        # Theirs leads (holds extra samples first), or ours does.
        for leader, follower, who in ((second, first, "installed ffmpeg"), (first, second, "harness")):
            overlap = min(len(leader) - shift, len(follower))
            if overlap <= 0 or leader[shift:shift + 64] != follower[:64]:
                continue
            if leader[shift:shift + overlap] == follower[:overlap]:
                skipped = max((abs(value) for value in leader[:shift]), default=0)
                return {"identical": False, "identical_after_lead": True, "leader": who, "lead_frames": frames,
                        "lead_peak": skipped, "our_samples": len(first), "their_samples": len(second)}
    count = min(len(first), len(second))
    largest = max((abs(a - b) for a, b in zip(first[:count], second[:count])), default=0)
    peak = max((abs(value) for value in second), default=0)
    return {"identical": False, "our_samples": len(first), "their_samples": len(second),
            "largest_difference": largest, "peak": peak}


def decode(set_name, variant, work):
    """Runs one Mac build's harness on copies of the test samples whose
    container the set reads, and compares each decode with the installed
    ffmpeg's. Records decode.json."""
    folder = build_folder(work, set_name, "macos", variant)
    harness = folder / "harness" / "harness"
    if not harness.exists():
        print(f"decode: {folder.name} has no harness", flush=True)
        return None
    samples_folder = Path(work) / "samples"
    output_folder = folder / "decoded"
    output_folder.mkdir(exist_ok=True)
    results = []
    for sample, demuxer in SAMPLES:
        if demuxer not in SETS[set_name]["demuxers"]:
            continue
        # A copy of the sample in the scratch folder, never the repository's own file.
        copy = samples_folder / sample
        copy.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(SAMPLES_FOLDER / sample, copy)
        stem = sample.replace("/", "_")
        ours = output_folder / f"{stem}.harness.raw"
        result = {"sample": sample, "demuxer": demuxer}
        try:
            run = subprocess.run([str(harness), demuxer, str(copy), str(ours)], capture_output=True,
                                 text=True, timeout=90, check=False)
        except subprocess.TimeoutExpired:
            result["harness"] = "timed out"
            results.append(result)
            continue
        result["status"] = run.returncode
        result["stderr"] = run.stderr.strip()[-500:]
        if run.returncode != 0 or not run.stdout.strip():
            results.append(result)
            continue
        summary = json.loads(run.stdout.strip().splitlines()[-1])
        result["harness"] = summary
        raw_format = RAW_FORMATS.get(summary.get("sample_format", ""))
        if raw_format and INSTALLED_FFMPEG.exists():
            encoder, muxer = raw_format
            theirs = output_folder / f"{stem}.installed.raw"
            reference = [str(INSTALLED_FFMPEG), "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                         "-protocol_whitelist", "file", "-c:a", summary["decoder"], "-f", demuxer,
                         "-i", f"file:{copy}", "-map", f"0:{summary['stream']}", "-c:a", encoder, "-f", muxer,
                         f"file:{theirs}"]
            try:
                made = subprocess.run(reference, capture_output=True, text=True, timeout=90, check=False)
                if made.returncode == 0:
                    result["installed_ffmpeg"] = compare_samples(ours.read_bytes(), theirs.read_bytes(), muxer,
                                                                 summary.get("channels", 1))
                else:
                    result["installed_ffmpeg"] = {"error": made.stderr.strip()[-500:]}
            except subprocess.TimeoutExpired:
                result["installed_ffmpeg"] = {"error": "timed out"}
        results.append(result)
    write_json(folder / "decode.json", results)
    print(f"decode: {folder.name}: {len(results)} samples", flush=True)
    return results


# ---------------------------------------------------------------------------
# tree
# ---------------------------------------------------------------------------

def dependency_paths(dependency_file):
    """The paths a compiler dependency file (.d) lists: the object's source and
    every header it included (system headers are not listed, with -MMD)."""
    text = Path(dependency_file).read_text(encoding="utf-8", errors="replace").replace("\\\n", " ")
    paths = []
    for line in text.splitlines():
        if ":" not in line:
            continue
        _target, _, rest = line.partition(": ")
        paths += rest.split()
    return paths


def tree(set_name, platform, variant, source, work):
    """tree_of_folder for one build, by its set, platform, and variant."""
    return tree_of_folder(build_folder(work, set_name, platform, variant), source)


def tree_of_folder(folder, source):
    """What a vendored, trimmed copy of FFmpeg's source would hold for the
    build in `folder`: every source file and header the build compiled or
    included, from its dependency files, in FFmpeg's tree or generated by
    configure. Records their number and bytes in tree.json; reads only their
    names and sizes."""
    folder = Path(folder).resolve()
    source = Path(source).resolve()
    from_source, generated = {}, {}
    for dependency_file in folder.rglob("*.d"):
        if "install" in dependency_file.relative_to(folder).parts:
            continue
        for path in dependency_paths(dependency_file):
            # A relative path is relative to where make ran: the build folder.
            resolved = Path(path).resolve() if os.path.isabs(path) else (folder / path).resolve()
            if resolved.is_relative_to(source):
                from_source[str(resolved.relative_to(source))] = resolved.stat().st_size
            elif resolved.is_relative_to(folder.resolve()):
                generated[str(resolved.relative_to(folder.resolve()))] = resolved.stat().st_size
    by_kind = {}
    for name, size in from_source.items():
        kind = Path(name).suffix or "(none)"
        count, total = by_kind.get(kind, (0, 0))
        by_kind[kind] = (count + 1, total + size)
    record = {
        "name": folder.name,
        "source_files": len(from_source),
        "source_bytes": sum(from_source.values()),
        "by_suffix": {kind: {"files": count, "bytes": total} for kind, (count, total) in sorted(by_kind.items())},
        "generated_files": generated,
        "source_list": sorted(from_source),
    }
    write_json(folder / "tree.json", record)
    print(f"tree: {folder.name}: {record['source_files']} files, {record['source_bytes']:,} bytes", flush=True)
    return record


# ---------------------------------------------------------------------------
# xcframework
# ---------------------------------------------------------------------------

def folder_bytes(folder):
    """The bytes of every file under `folder`."""
    return sum(path.stat().st_size for path in Path(folder).rglob("*") if path.is_file())


def xcframework(set_name, variant, work):
    """Makes an XCFramework of one set's libraries for the Mac, the iPhone, and
    the iPhone simulator (each platform's three libraries joined into one), and
    records its size as it is and compressed, as git would store it."""
    out = Path(work) / "xcframework" / f"{set_name}-{variant}"
    out.mkdir(parents=True, exist_ok=True)
    arguments = ["xcodebuild", "-create-xcframework"]
    for platform in ("macos", "ios", "iossim"):
        folder = build_folder(work, set_name, platform, variant)
        if not (folder / "build.json").exists():
            print(f"xcframework: {folder.name} was not built", flush=True)
            return None
        joined = out / f"libffmpeg-minimal-{platform}.a"
        libraries = [str(path) for path in built_libraries(folder / "install")]
        run_text([tool_path("libtool"), "-static", "-o", str(joined)] + libraries)
        arguments += ["-library", str(joined), "-headers", str(folder / "install" / "include")]
    framework = out / f"FFmpegMinimal-{time.strftime('%Y%m%d-%H%M%S')}.xcframework"
    run_text(arguments + ["-output", str(framework)])
    archive = out / f"{framework.name}.tar.gz"
    with tarfile.open(archive, "w:gz", compresslevel=9) as bundle:
        bundle.add(framework, arcname=framework.name)
    record = {"framework": str(framework), "bytes": folder_bytes(framework), "gzip_bytes": archive.stat().st_size,
              "libraries": {path.name: path.stat().st_size for path in sorted(framework.rglob("*.a"))}}
    write_json(out / "xcframework.json", record)
    print(f"xcframework: {set_name}-{variant}: {record['bytes']:,} bytes, {record['gzip_bytes']:,} compressed", flush=True)
    return record


# ---------------------------------------------------------------------------
# all, and report
# ---------------------------------------------------------------------------

def run_all(source, work, only=None):
    """Every build of ALL_BUILDS (or those `only` names, such as
    "macos-a-small"), each measured, and the decode of each Mac build. A step
    that fails is recorded and the rest go on. The builds are the heavy part,
    run under the heavy-work lock; `only` lets them go in several runs, so
    the lock is never held long."""
    for set_name, platform, variant in ALL_BUILDS:
        if only and build_name(set_name, platform, variant) not in only:
            continue
        try:
            if build(set_name, platform, variant, source, work).get("error"):
                continue
            measure(set_name, platform, variant, work)
            if platform == "macos":
                decode(set_name, variant, work)
        except Exception as error:  # noqa: BLE001 - one build's failure must not stop the rest
            print(f"all: {build_name(set_name, platform, variant)}: {error}", flush=True)


def finish(source, work):
    """The light steps after the builds: the trimmed tree of the parity set on
    each platform, and its XCFramework. Each failure is recorded and the rest
    go on."""
    for platform in ("macos", "ios", "iossim"):
        try:
            tree("a", platform, "small", source, work)
        except Exception as error:  # noqa: BLE001 - one step's failure must not stop the rest
            print(f"finish: tree {platform}: {error}", flush=True)
    try:
        xcframework("a", "small", work)
    except Exception as error:  # noqa: BLE001
        print(f"finish: xcframework: {error}", flush=True)


def report(work):
    """Prints, for every build recorded under WORK, its time, files, licence,
    and what it adds; then the decodes."""
    for folder in sorted((Path(work) / "builds").iterdir()):
        built = read_json(folder / "build.json") or read_json(folder / "build-failed.json")
        if not built:
            continue
        if built.get("error"):
            print(f"{folder.name}: FAILED: {built['error'][:300]}")
            continue
        measured = read_json(folder / "measure.json") or {}
        summary = built.get("summary", {})
        print(f"{folder.name}: licence {summary.get('license')}; threading {summary.get('threading')}; "
              f"compiled {built.get('compiled')}; configure {built['configure_seconds']['wall']} s, "
              f"make {built['make_seconds']['wall']} s wall, {built['make_seconds']['cpu']} s processor; "
              f"adds {measured.get('added_file_bytes', 0):,} file bytes, {measured.get('added_section_bytes', 0):,} section bytes")
        decoded = read_json(folder / "decode.json") or []
        for result in decoded:
            harness = result.get("harness", {})
            check = result.get("installed_ffmpeg", {})
            print(f"    {result['sample']}: {harness.get('decoder', result.get('stderr', ''))} "
                  f"{harness.get('samples', '')} samples; installed ffmpeg: {check}")


def main():
    """Reads the command line and runs one step."""
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("step", choices=["all", "finish", "build", "measure", "decode", "tree", "xcframework", "report"])
    parser.add_argument("--set", dest="set_name", choices=sorted(SETS), default="a")
    parser.add_argument("--platform", choices=sorted(PLATFORMS), default="macos")
    parser.add_argument("--variant", choices=sorted(VARIANTS), default="small")
    parser.add_argument("--only", help="for all: the builds to make, by name, separated by commas (macos-a-small,...)")
    parser.add_argument("--source", help="the unpacked FFmpeg release")
    parser.add_argument("--work", required=True, help="the scratch folder")
    options = parser.parse_args()
    work = Path(options.work).resolve()
    work.mkdir(parents=True, exist_ok=True)
    if options.step in ("all", "finish", "build", "tree") and not options.source:
        parser.error(f"{options.step} needs --source")
    if options.step == "all":
        run_all(Path(options.source).resolve(), work, set(options.only.split(",")) if options.only else None)
    elif options.step == "finish":
        finish(Path(options.source).resolve(), work)
    elif options.step == "build":
        build(options.set_name, options.platform, options.variant, Path(options.source).resolve(), work)
    elif options.step == "measure":
        measure(options.set_name, options.platform, options.variant, work)
    elif options.step == "decode":
        decode(options.set_name, options.variant, work)
    elif options.step == "tree":
        tree(options.set_name, options.platform, options.variant, options.source, work)
    elif options.step == "xcframework":
        xcframework(options.set_name, options.variant, work)
    if options.step in ("all", "finish", "report"):
        report(work)
    return 0


if __name__ == "__main__":
    sys.exit(main())
