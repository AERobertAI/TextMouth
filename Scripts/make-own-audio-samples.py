#!/usr/bin/env python3
"""Make the test files of TextMouth's own audio readers (True Audio, WavPack, Monkey's Audio).

Usage:
    python3 -I -B Scripts/make-own-audio-samples.py --out TestData/format-samples \\
        --work <scratch folder> [--ffmpeg PATH] [--wavpack PATH] [--mac PATH] FORMAT [FORMAT ...]

FORMAT is tta, wv, or ape. Every recording is made here, from tones under a
syllable-like envelope with a little noise, so nothing comes from outside and
every file is CC0. Each recording is encoded by the encoder named (the
installed ffmpeg run as a program, or the format's own BSD-licensed encoder
built from its pinned source) into `<out>/<format>/`, and `<out>/<format>/pcm.tsv`
lists, for every file, the shape of its audio and the SHA-256 of the sample
bytes the source WAV held (8-bit samples unsigned, wider ones little-endian),
which a decoder of a lossless file must give back exactly.

The rows for samples.tsv are printed. Nothing is deleted: files are
overwritten in place, and the source WAVs stay in the work folder.
"""
import argparse
import hashlib
import math
import os
import struct
import subprocess
import sys

LIMIT_SECONDS = 300


def run(arguments):
    """Run a child process with a time limit; exits with its message when it fails."""
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=LIMIT_SECONDS,
                            stdin=subprocess.DEVNULL)
    if result.returncode != 0:
        sys.exit(f"{arguments[0]} failed ({result.returncode}): {result.stderr.strip()[:400]}")


class Noise:
    """A small fixed generator, so every run makes the same recordings."""

    def __init__(self, seed):
        self.state = seed & 0xFFFFFFFF

    def next(self):
        """A number from -1 to 1."""
        self.state = (self.state * 1664525 + 1013904223) & 0xFFFFFFFF
        return (self.state >> 8) / 8388608.0 - 1.0


def recording(rate, channels, seconds, seed, noise_level):
    """Frames of numbers from -1 to 1: two tones a channel under a syllable-like envelope, plus noise."""
    noise = Noise(seed)
    frames = []
    for index in range(int(round(rate * seconds))):
        t = index / rate
        envelope = 0.5 * (1 - math.cos(2 * math.pi * 3.1 * t)) * (0.6 + 0.4 * math.sin(2 * math.pi * 0.7 * t))
        frame = []
        for channel in range(channels):
            pitch = 140 + 35 * channel
            value = 0.45 * math.sin(2 * math.pi * pitch * t) + 0.2 * math.sin(2 * math.pi * pitch * 2.5 * t + channel)
            value = value * envelope + noise_level * noise.next()
            frame.append(max(-1.0, min(1.0, value * 0.9)))
        frames.append(frame)
    return frames


def pcm_bytes(frames, bits, is_float, container=None):
    """The sample bytes a WAV file stores: 8-bit unsigned, wider ones little-endian signed, or 32-bit floats.
    A sample of `bits` bits sits at the top of its bytes: the fewest that hold it, or `container` bits."""
    out = bytearray()
    if is_float:
        for frame in frames:
            for value in frame:
                out += struct.pack("<f", value)
        return bytes(out)
    width = (container or bits + 7) // 8
    top = (1 << (bits - 1)) - 1
    for frame in frames:
        for value in frame:
            number = int(round(value * top)) << (width * 8 - bits)
            if width == 1:
                out.append((number + 128) & 0xFF)
            else:
                out += (number & ((1 << (width * 8)) - 1)).to_bytes(width, "little")
    return bytes(out)


def special_floats(frames):
    """The bytes of `frames` as floats, in runs of 97 frames: zeros, negative zeros, the sound, and the sound
    with an infinity, a value that is not a number, or a value far above full scale every seventh sample."""
    specials = [0x7F800000, 0xFF800000, 0x7FC00000, 0x7F800001, 0xFFC12345]
    out = bytearray()
    count = 0
    for index, frame in enumerate(frames):
        phase = (index // 97) % 4
        for value in frame:
            count += 1
            if phase == 0:
                out += struct.pack("<I", 0x00000000)
            elif phase == 1:
                out += struct.pack("<I", 0x80000000)
            elif phase == 3 and count % 7 == 0:
                out += struct.pack("<I", specials[(count // 7) % len(specials)])
            elif phase == 3 and count % 7 == 3:
                out += struct.pack("<f", value * 3000.0)
            else:
                out += struct.pack("<f", value)
    return bytes(out)


def write_wav(path, rate, channels, bits, data, is_float, mask, container=None):
    """A WAV file of `data`: plain PCM, or WAVE_FORMAT_EXTENSIBLE when a mask, many channels, or samples of
    fewer bits than their bytes (`bits` valid in `container`) need it."""
    width = (container or bits + 7) // 8
    block = width * channels
    tag = 3 if is_float else 1
    if mask is not None or channels > 2 or width * 8 != bits:
        # The sub-format GUID of PCM or IEEE float, after its two-byte tag.
        sub = struct.pack("<H", tag) + bytes.fromhex("000000001000800000aa00389b71")
        fmt = struct.pack("<HHIIHHHHI", 0xFFFE, channels, rate, rate * block, block, width * 8, 22, bits,
                          mask if mask is not None else 0) + sub
    else:
        fmt = struct.pack("<HHIIHH", tag, channels, rate, rate * block, block, width * 8)
    body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(data)) + data
    if len(data) % 2:
        body += b"\0"
    with open(path, "wb") as handle:
        handle.write(b"RIFF" + struct.pack("<I", len(body)) + body)


class Shape:
    """One recording: its name and what its audio is."""

    def __init__(self, name, rate, channels, bits, seconds, seed, is_float=False, mask=None, noise=None,
                 silent_frames=0, same_channels=False, float_kind=None, container=None):
        self.name, self.rate, self.channels, self.bits = name, rate, channels, bits
        self.seconds, self.seed, self.is_float, self.mask = seconds, seed, is_float, mask
        # How many frames at the start are digital silence, and whether every channel repeats the first.
        self.silent_frames, self.same_channels = silent_frames, same_channels
        # For floats: "from16" (16-bit whole numbers scaled down, so every mantissa ends in zeros) or
        # "specials" (runs of zeros and negative zeros, with infinities and values that are not numbers).
        # For 32-bit whole numbers: "as32" (each made from a single-precision float).
        self.float_kind = float_kind
        # The bits a sample's bytes hold in the WAV file, when more than the fewest `bits` need (24 in 32).
        self.container = container
        # Noise of about eight steps of the sample's own depth keeps every file small.
        self.noise = noise if noise is not None else 8 / (1 << (min(bits, 24) - 1))

    def make(self, work):
        """Write the source WAV into `work`; returns (path, frames, SHA-256 of its sample bytes)."""
        frames = recording(self.rate, self.channels, self.seconds, self.seed, self.noise)
        if self.same_channels:
            frames = [[frame[0]] * self.channels for frame in frames]
        frames = [[0.0] * self.channels] * self.silent_frames + frames
        if self.float_kind == "from16":
            frames = [[round(value * 32767) / 32768.0 for value in frame] for frame in frames]
        data = pcm_bytes(frames, self.bits, self.is_float)
        if self.float_kind == "specials":
            data = special_floats(frames)
        if self.float_kind == "as32":
            # 32-bit whole numbers made from single-precision floats: only 24 bits of each are busy.
            data = b"".join(struct.pack("<i", max(-(1 << 31), min((1 << 31) - 1, int(
                struct.unpack("<f", struct.pack("<f", value))[0] * 2147483648.0)))) for frame in frames for value in frame)
        path = os.path.join(work, self.name + ".wav")
        # The digest is of each sample in the fewest bytes that hold it, which a wider file's are not.
        stored = pcm_bytes(frames, self.bits, self.is_float, self.container) if self.container else data
        write_wav(path, self.rate, self.channels, self.bits, stored, self.is_float, self.mask, self.container)
        return path, len(frames), hashlib.sha256(data).hexdigest()


# ---------------------------------------------------------------- tags

def synchsafe(number):
    """A number as the four 7-bit bytes ID3v2 writes sizes in."""
    return bytes([(number >> 21) & 0x7F, (number >> 14) & 0x7F, (number >> 7) & 0x7F, number & 0x7F])


def id3v2_tag(fields):
    """An ID3v2.3 tag of text frames; `fields` maps a frame's name to (text, encoding byte)."""
    frames = b""
    for name, (text, encoding) in fields.items():
        body = bytes([encoding]) + (b"\xff\xfe" + text.encode("utf-16-le") if encoding == 1 else text.encode("latin-1"))
        frames += name.encode("ascii") + struct.pack(">I", len(body)) + b"\0\0" + body
    return b"ID3\x03\x00\x00" + synchsafe(len(frames)) + frames


def apev2_tag(items):
    """An APEv2 tag (header, items, footer) of UTF-8 text items."""
    body = b""
    for key, value in items.items():
        data = value.encode("utf-8")
        body += struct.pack("<II", len(data), 0) + key.encode("ascii") + b"\0" + data
    size = len(body) + 32

    def edge(flags):
        return b"APETAGEX" + struct.pack("<IIII", 2000, size, len(items), flags) + bytes(8)

    return edge(0xA0000000) + body + edge(0x80000000)


def id3v1_tag(title, artist, album, year):
    """An ID3v1 tag: fixed fields of Latin-1 text."""
    def field(text, length):
        return text.encode("latin-1")[:length].ljust(length, b"\0")

    return b"TAG" + field(title, 30) + field(artist, 30) + field(album, 30) + field(year, 4) + bytes(30) + b"\xff"


CUE_SHEET = ('PERFORMER "Odalys Brennecke"\nTITLE "Ferry Timetables"\nFILE "tagged.wav" WAVE\n'
             '  TRACK 01 AUDIO\n    TITLE "Morning Crossings"\n    INDEX 01 00:00:00\n'
             '  TRACK 02 AUDIO\n    TITLE "Evening Crossings"\n    INDEX 01 00:00:15\n')

APE_ITEMS = {"Title": "Ferry Timetables", "Artist": "Odalys Brennecke", "Album": "Harbour Notices",
             "Year": "2026", "Genre": "Speech", "Cuesheet": CUE_SHEET}


# ---------------------------------------------------------------- formats

def sha256_of(path):
    """A file's SHA-256."""
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


class Maker:
    """Collects the files of one format, their pcm.tsv lines, and their samples.tsv rows."""

    def __init__(self, format_name, out, work):
        self.format = format_name
        self.folder = os.path.join(out, format_name)
        self.work = work
        self.pcm_lines = []
        self.rows = []
        os.makedirs(self.folder, exist_ok=True)
        os.makedirs(work, exist_ok=True)

    def add(self, file_name, shape, frames, digest, source, exercises, lossless=True):
        """Record one encoded file, already written into the format's folder."""
        path = os.path.join(self.folder, file_name)
        self.pcm_lines.append("\t".join([
            file_name, str(shape.rate), str(shape.channels), str(shape.bits), "1" if shape.is_float else "0",
            "1" if lossless else "0", str(frames), digest if lossless else "-"]))
        pcm = f"source PCM SHA-256 {digest}" if lossless else "lossy, so no PCM digest"
        self.rows.append("\t".join([
            self.format, f"{self.format}/{file_name}", source, "CC0-1.0", str(os.path.getsize(path)),
            sha256_of(path), f"{exercises}; {pcm} ({self.format}/pcm.tsv)"]))

    def add_companion(self, file_name, source, exercises):
        """Record a file that completes another (a WavPack correction file): a row, and no line in pcm.tsv."""
        path = os.path.join(self.folder, file_name)
        self.rows.append("\t".join([
            self.format, f"{self.format}/{file_name}", source, "CC0-1.0", str(os.path.getsize(path)),
            sha256_of(path), exercises]))

    def finish(self, kept_lines=()):
        """Write pcm.tsv (with `kept_lines`, the lines of files made elsewhere) and print the rows."""
        header = "file\tsample rate\tchannels\tbits\tfloat\tlossless\tframes\tsha256 of the source's sample bytes"
        with open(os.path.join(self.folder, "pcm.tsv"), "w") as handle:
            handle.write("\n".join([header] + list(kept_lines) + self.pcm_lines) + "\n")
        print("\n".join(self.rows))


def make_tta(arguments):
    """True Audio: the installed ffmpeg's encoder (the format's own encoder is not permissively licensed)."""
    maker = Maker("tta", arguments.out, arguments.work)
    made_by = "made on this Mac: Scripts/make-own-audio-samples.py tta (ffmpeg 7.1.1 -fflags +bitexact -c:a tta)"
    shapes = [
        (Shape("mono8", 8000, 1, 8, 0.5, 21), "8-bit mono 8 kHz: the 8-bit filter shift and predictor"),
        (Shape("mono16", 22050, 1, 16, 0.4, 22), "16-bit mono 22.05 kHz"),
        (Shape("stereo16", 44100, 2, 16, 0.3, 23), "16-bit stereo 44.1 kHz: the channels' differences undone"),
        (Shape("stereo24", 48000, 2, 24, 0.25, 24), "24-bit stereo 48 kHz"),
        (Shape("six16", 48000, 6, 16, 0.1, 25), "16-bit, six channels, with no layout (refused at import)"),
        (Shape("short16", 44100, 2, 16, 0.005, 26), "220 frames: shorter than one True Audio frame"),
        (Shape("tagged16", 11025, 1, 16, 0.3, 27), "an odd sample rate"),
    ]
    for shape, exercises in shapes:
        source, frames, digest = shape.make(arguments.work)
        encoded = os.path.join(maker.folder, shape.name + ".tta")
        run([arguments.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source,
             "-map_metadata", "-1", "-fflags", "+bitexact", "-c:a", "tta", encoded])
        if shape.name == "tagged16":
            # The three tags a True Audio file may carry, each naming a different title,
            # so a test can tell which one a reader took.
            with open(encoded, "rb") as handle:
                audio = handle.read()
            start = audio.find(b"TTA1")
            leading = id3v2_tag({"TIT2": ("Title from ID3v2", 1), "TPE1": ("Artist from ID3v2", 0),
                                 "TCON": ("(101)Speech from ID3v2", 0)})
            with open(encoded, "wb") as handle:
                handle.write(leading + audio[start:] + apev2_tag(APE_ITEMS)
                             + id3v1_tag("Title from ID3v1", "Artist from ID3v1", "Album from ID3v1", "1999"))
            exercises += ", after an ID3v2 tag and before an APEv2 tag (with a cue sheet) and an ID3v1 tag"
        maker.add(shape.name + ".tta", shape, frames, digest, made_by, "True Audio: " + exercises)
    # tones.tta was made on October 17, 2026 from a recording no longer at hand; three decoders
    # agreed on its samples on November 15, 2026 (MD5 41daa1386798de0026a3d184be9ea40f).
    maker.finish(kept_lines=[
        "tones.tta\t22050\t1\t16\t0\t1\t66150\t" + arguments.tones_tta_digest] if arguments.tones_tta_digest else [])


def make_wv(arguments):
    """WavPack: its own encoder (5.9.0, built from the BSD source) in each mode, and the installed ffmpeg's."""
    if not arguments.wavpack:
        sys.exit("wv needs --wavpack, the encoder built from WavPack's source")
    maker = Maker("wv", arguments.out, arguments.work)
    own = "made on this Mac: Scripts/make-own-audio-samples.py wv (wavpack 5.9.0, built from its BSD source, {})"
    # name, shape, the encoder's options, what a test checks
    files = [
        ("mono16-fast", Shape("wv-mono16", 22050, 1, 16, 0.4, 41), ["-f"], "lossless mono, fast mode"),
        ("stereo16", Shape("wv-stereo16", 44100, 2, 16, 0.25, 42), [], "lossless joint stereo, normal mode"),
        ("stereo16-high", Shape("wv-stereo16h", 44100, 2, 16, 0.25, 43), ["-h", "-j0"],
         "lossless left and right stereo, high mode"),
        ("stereo24-veryhigh", Shape("wv-stereo24", 48000, 2, 24, 0.2, 44), ["-hh", "-x3"],
         "24 bits, very high mode with extra processing"),
        ("mono8", Shape("wv-mono8", 8000, 1, 8, 0.5, 45), [], "8 bits"),
        ("stereo32", Shape("wv-stereo32", 44100, 2, 32, 0.1, 46), [],
         "32-bit whole numbers: the low bits in the extra bitstream"),
        ("float32", Shape("wv-float32", 44100, 2, 32, 0.1, 47, is_float=True), [],
         "32-bit floats, rebuilt from the extra bitstream"),
        ("floatmono-fast", Shape("wv-floatmono", 16000, 1, 32, 0.2, 48, is_float=True), ["-f"], "32-bit floats, mono"),
        ("floatfrom16", Shape("wv-floatfrom16", 22050, 2, 32, 0.15, 66, is_float=True, float_kind="from16"), [],
         "floats made from 16-bit numbers: the bits shifted into each mantissa are zeros, not sent"),
        ("floatspecials-high", Shape("wv-floatspecials", 22050, 1, 32, 0.2, 67, is_float=True, float_kind="specials"),
         ["-h"], "floats with zeros, negative zeros, infinities, values that are not numbers, and values above 1"),
        ("hybridfloatfrom16", Shape("wv-hybridfloatfrom16", 22050, 1, 32, 0.15, 68, is_float=True, float_kind="from16"),
         ["-b4", "-c"], "hybrid floats made from 16-bit numbers"),
        ("int32fromfloat-optimized", Shape("wv-int32fromfloat", 22050, 2, 32, 0.15, 69, float_kind="as32"),
         ["--optimize-int32", "-f"],
         "32-bit numbers made from floats, with --optimize-int32: the newer extra bitstream and its width limit"),
        ("shift12", Shape("wv-shift12", 22050, 1, 12, 0.2, 70), [],
         "12 bits in 16-bit samples: a header shift of 4"),
        ("shift20", Shape("wv-shift20", 44100, 2, 20, 0.1, 71), ["-h"],
         "20 bits in 24-bit samples: a header shift of 4"),
        ("shift24in32", Shape("wv-shift24in32", 48000, 2, 24, 0.1, 72, container=32), [],
         "24 bits in 32-bit samples: a header shift of 8"),
        ("hybridshift20", Shape("wv-hybridshift20", 44100, 1, 20, 0.1, 73), ["-b4", "-c"],
         "hybrid, 20 bits in 24-bit samples"),
        ("six16", Shape("wv-six16", 48000, 6, 16, 0.1, 49, mask=0x3F), [],
         "5.1 in four blocks a stretch, with its channel mask (mixed to stereo at import)"),
        ("short16", Shape("wv-short16", 44100, 2, 16, 0.002, 50), [], "88 frames in one small block"),
        ("blocks16", Shape("wv-blocks16", 22050, 2, 16, 0.2, 51), ["--blocksize=128"], "35 blocks of 128 frames"),
        ("rate12345", Shape("wv-rate12345", 12345, 1, 16, 0.3, 52), ["-m"],
         "a sample rate stored in the metadata, and an MD5 block at the end"),
        ("hybrid16", Shape("wv-hybrid16", 44100, 2, 16, 0.25, 53), ["-b256", "-c"],
         "hybrid stereo, lossless with hybrid16.wvc beside it and lossy alone"),
        ("hybridmono16", Shape("wv-hybridmono16", 22050, 1, 16, 0.3, 54), ["-b3", "-c"], "hybrid mono, 3 bits a sample"),
        ("hybridshape24", Shape("wv-hybridshape24", 48000, 2, 24, 0.15, 55), ["-b3.5", "-c", "-s-0.5"],
         "hybrid with negative noise shaping, 24 bits"),
        ("hybridcross16", Shape("wv-hybridcross16", 44100, 2, 16, 0.2, 56), ["-b4", "-c", "--cross-decorr", "-hh"],
         "hybrid with cross-channel decorrelation, very high mode"),
        ("hybridfloat", Shape("wv-hybridfloat", 44100, 2, 32, 0.1, 57, is_float=True), ["-b320", "-c"],
         "hybrid floats: the extra bitstream is in the correction file"),
        ("hybrid32", Shape("wv-hybrid32", 32000, 1, 32, 0.1, 58), ["-b4", "-c"], "hybrid 32-bit whole numbers"),
        ("hybridsix16", Shape("wv-hybridsix16", 48000, 6, 16, 0.05, 59, mask=0x3F), ["-b3", "-c"],
         "hybrid 5.1: each block of the stretch has its correction block"),
        ("lossy16", Shape("wv-lossy16", 44100, 2, 16, 0.25, 60), ["-b3"],
         "hybrid without a correction file: lossy, converted to AAC"),
    ]
    for name, shape, options, exercises in files:
        source, frames, digest = shape.make(arguments.work)
        encoded = os.path.join(maker.folder, name + ".wv")
        run([arguments.wavpack, "-y", "-q"] + options + [source, "-o", encoded])
        made_by = own.format(" ".join(options) if options else "default options")
        maker.add(name + ".wv", shape, frames, digest, made_by, "WavPack: " + exercises, lossless=name != "lossy16")
        if "-c" in options:
            maker.add_companion(name + ".wvc", made_by, f"WavPack: the correction file of {name}.wv")

    # The same kind of recording with tags the encoder writes itself, a cue sheet among them.
    shape = Shape("wv-tagged16", 11025, 1, 16, 0.3, 61)
    source, frames, digest = shape.make(arguments.work)
    cue = os.path.join(arguments.work, "tagged.cue")
    with open(cue, "w") as handle:
        handle.write(CUE_SHEET)
    options = sum((["-w", f"{key}={value}"] for key, value in APE_ITEMS.items() if key != "Cuesheet"), [])
    run([arguments.wavpack, "-y", "-q"] + options + ["-w", "Cuesheet=@" + cue, source, "-o",
                                                     os.path.join(maker.folder, "tagged16.wv")])
    maker.add("tagged16.wv", shape, frames, digest, own.format('-w "Field=Value" tags and -w Cuesheet=@tagged.cue'),
              "WavPack: an APEv2 tag written by the encoder, with a cue sheet")

    # ffmpeg's encoder writes 24-bit sound as 32-bit samples, so its files here are 16 and 32 bits.
    ffmpeg = "made on this Mac: Scripts/make-own-audio-samples.py wv (ffmpeg 7.1.1 -fflags +bitexact -c:a wavpack)"
    for name, shape, exercises in [
        ("ffmpeg-mono16", Shape("wv-ffmpeg-mono16", 22050, 1, 16, 0.4, 62), "ffmpeg's encoder, mono"),
        ("ffmpeg-stereo16", Shape("wv-ffmpeg-stereo16", 44100, 2, 16, 0.25, 63), "ffmpeg's encoder, stereo"),
        ("ffmpeg-stereo32", Shape("wv-ffmpeg-stereo32", 44100, 2, 32, 0.1, 64), "ffmpeg's encoder, 32 bits"),
        ("ffmpeg-six16", Shape("wv-ffmpeg-six16", 48000, 6, 16, 0.1, 65, mask=0x3F), "ffmpeg's encoder, 5.1"),
    ]:
        source, frames, digest = shape.make(arguments.work)
        encoded = os.path.join(maker.folder, name + ".wv")
        run([arguments.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source,
             "-map_metadata", "-1", "-fflags", "+bitexact", "-c:a", "wavpack", encoded])
        maker.add(name + ".wv", shape, frames, digest, ffmpeg, "WavPack: " + exercises)
    # tones.wv was made on October 17, 2026 from the recording tones.tta was made from.
    maker.finish(kept_lines=[
        "tones.wv\t22050\t1\t16\t0\t1\t66150\t" + arguments.tones_tta_digest] if arguments.tones_tta_digest else [])


def make_ape(arguments):
    """Monkey's Audio: its own encoder (SDK 13.47, built from the BSD source) at every level; ffmpeg has none."""
    if not arguments.mac:
        sys.exit("ape needs --mac, the encoder built from the Monkey's Audio SDK")
    maker = Maker("ape", arguments.out, arguments.work)
    own = "made on this Mac: Scripts/make-own-audio-samples.py ape (mac 13.47, built from the SDK's BSD source, {})"
    # A full frame of the levels below Insane: 73,728 * 4 audio frames.
    full = 294_912
    # name, shape, the level, what a test checks
    files = [
        ("mono16-fast", Shape("ape-mono16", 22050, 1, 16, 0.4, 71), "-c1000", "mono, Fast: no adaptive filter"),
        ("stereo16-normal", Shape("ape-stereo16n", 44100, 2, 16, 0.25, 72), "-c2000", "stereo, Normal: one filter of 16"),
        ("stereo16-high", Shape("ape-stereo16h", 44100, 2, 16, 0.25, 73), "-c3000", "stereo, High: one filter of 64"),
        ("stereo16-extrahigh", Shape("ape-stereo16x", 44100, 2, 16, 0.15, 74), "-c4000",
         "stereo, Extra High: filters of 32 and 256"),
        ("stereo16-insane", Shape("ape-stereo16i", 44100, 2, 16, 0.1, 75), "-c5000",
         "stereo, Insane: filters of 16, 256, and 1,280"),
        ("mono8-normal", Shape("ape-mono8", 8000, 1, 8, 0.5, 76), "-c2000", "8 bits"),
        ("stereo8-high", Shape("ape-stereo8", 11025, 2, 8, 0.3, 77), "-c3000", "8-bit stereo: the pair wraps at 8 bits"),
        ("stereo24-normal", Shape("ape-stereo24", 48000, 2, 24, 0.2, 78), "-c2000", "24 bits"),
        ("mono24-extrahigh", Shape("ape-mono24", 32000, 1, 24, 0.2, 79), "-c4000", "24-bit mono, Extra High"),
        ("stereo32-normal", Shape("ape-stereo32", 44100, 2, 32, 0.1, 80), "-c2000",
         "32-bit whole numbers: the 64-bit predictor and the 32-bit filter"),
        ("mono32-insane", Shape("ape-mono32", 32000, 1, 32, 0.1, 81), "-c5000", "32-bit mono, Insane"),
        ("float32-fast", Shape("ape-float32", 44100, 2, 32, 0.1, 82, is_float=True), "-c1000",
         "32-bit floats (signature MACF): the float transform undone"),
        ("floatmono-high", Shape("ape-floatmono", 16000, 1, 32, 0.2, 83, is_float=True), "-c3000", "32-bit floats, mono"),
        ("floatspecials-normal", Shape("ape-floatspecials", 22050, 1, 32, 0.2, 94, is_float=True, float_kind="specials"),
         "-c2000", "floats with zeros, negative zeros, infinities, values that are not numbers, and values above 1"),
        ("three16-normal", Shape("ape-three16", 44100, 3, 16, 0.1, 84, mask=0x7), "-c2000",
         "three channels: none stored as a pair"),
        ("four24-fast", Shape("ape-four24", 44100, 4, 24, 0.1, 85, mask=0x33), "-c1000", "four channels: two pairs"),
        ("six16-normal", Shape("ape-six16", 48000, 6, 16, 0.1, 86, mask=0x3F), "-c2000",
         "5.1: the fronts and the surrounds as pairs (no layout in the file: refused at import)"),
        ("eight16-high", Shape("ape-eight16", 44100, 8, 16, 0.05, 87, mask=0x63F), "-c3000", "7.1: three pairs"),
        ("short16-normal", Shape("ape-short16", 44100, 2, 16, 0.002, 88), "-c2000", "88 frames"),
        ("pseudostereo16-normal", Shape("ape-pseudo16", 22050, 2, 16, 0.3, 89, same_channels=True), "-c2000",
         "both channels alike: the frame is coded as one channel"),
        ("silentstereo16-fast", Shape("ape-silent16", 22050, 2, 16, 0.0, 90, silent_frames=4000), "-c1000",
         "digital silence in stereo: a frame with no residuals"),
        ("twoframes16mono-normal", Shape("ape-twoframes16mono", 8000, 1, 16, 0.4, 91, silent_frames=full), "-c2000",
         "two mono frames: a full one of silence (coded as silent), then tones in a second frame"),
        ("twoframes16-fast", Shape("ape-twoframes16", 8000, 2, 16, 0.2, 92, silent_frames=full), "-c1000",
         "two stereo frames: a full silent one, then tones"),
    ]
    for name, shape, level, exercises in files:
        source, frames, digest = shape.make(arguments.work)
        encoded = os.path.join(maker.folder, name + ".ape")
        run([arguments.mac, source, encoded, level])
        maker.add(name + ".ape", shape, frames, digest, own.format(level), "Monkey's Audio: " + exercises)

    # The same kind of recording with the tags the encoder writes itself.
    shape = Shape("ape-tagged16", 11025, 1, 16, 0.3, 93)
    source, frames, digest = shape.make(arguments.work)
    fields = "|".join(f"{key}={value}" for key, value in APE_ITEMS.items() if key != "Cuesheet")
    run([arguments.mac, source, os.path.join(maker.folder, "tagged16.ape"), "-c2000", "-t", fields])
    maker.add("tagged16.ape", shape, frames, digest, own.format('-c2000 -t "Title=...|Artist=...|Album=...|Year=...|Genre=..."'),
              "Monkey's Audio: an APEv2 tag written by the encoder")
    maker.finish()


FORMATS = {"tta": make_tta, "wv": make_wv, "ape": make_ape}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("formats", nargs="+", choices=sorted(FORMATS))
    parser.add_argument("--out", required=True, help="TestData/format-samples")
    parser.add_argument("--work", required=True, help="a scratch folder for the source WAVs")
    parser.add_argument("--ffmpeg", default="/opt/homebrew/bin/ffmpeg")
    parser.add_argument("--wavpack", help="the wavpack encoder built from its BSD source")
    parser.add_argument("--mac", help="the Monkey's Audio encoder built from its BSD source")
    parser.add_argument("--tones-tta-digest",
                        help="the SHA-256 of the samples of tones.tta and tones.wv (one recording), kept in pcm.tsv")
    parsed = parser.parse_args()
    for name in parsed.formats:
        FORMATS[name](parsed)
