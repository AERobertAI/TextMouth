#!/usr/bin/env python3
"""packfile.py: the container both of TextMouth's packs are written in (FR39's `Strings.pack`, FR40's `BrailleTables.pack`).

One writer and one reader of the container, so the two packs cannot drift apart. Each pack's own builder
(`Scripts/l10n/pack.py`, `Scripts/packs/braille_tables.py`) decides what its blobs hold; this module knows only the
framing and the compression. The apps' reader is `TextMouth/Packs/PackContainer.swift`, which reads the same bytes.
Standard library only, and it runs under Xcode's /usr/bin/python3 (3.9).

The format, version-numbered by each pack (little-endian):
- The header, 48 bytes: the pack's magic (4 bytes), its format version (u16), flags (u16, zero), a SHA-256 of what the
  pack was built from (32 bytes), a count the pack gives its own meaning (u32: the number of IDs in `Strings.pack`, the
  number of table files in `BrailleTables.pack`), and the number of blobs (u32).
- The directory, 32 bytes a blob: its name (12 bytes of ASCII letters, digits, and hyphens, padded with NULs), its offset
  from the start of the file, its compressed size, its raw size, its entry count, and its method (u32 each).
- The blobs, each compressed by its record's method: 0, an xz stream (LZMA2), which Apple's COMPRESSION_LZMA decodes, or
  1, a bzip2 stream (level 9), which the system's libbz2 decodes.

The LZMA window. A blob's filter is given a dictionary size equal to the smallest power of two that is at least the
blob's raw size (and at least 4 KiB), with preset 9 extreme otherwise. For inputs this small it compresses as the 64 MiB
window does, give or take a few bytes, and it keeps the window a decoder may allocate small.

Determinism. The same input gives the same bytes with the same Python. Compare entries, not compressed bytes, between
Pythons: two builds of liblzma may encode the same input differently.
"""
from __future__ import annotations

import bz2
import lzma
import struct
from dataclasses import dataclass

# The magic, the version, the flags, the SHA-256 of the pack's source, the pack's count, the number of blobs.
HEADER = struct.Struct("<4sHH32sII")
# The name, then the offset, the compressed size, the raw size, the entry count, and the compression method.
DIRECTORY_RECORD = struct.Struct("<12sIIIII")
# The compression methods a directory record may name, and each one's name for the size report. LZMA is first, so that
# it wins a tie.
METHOD_LZMA, METHOD_BZIP2 = 0, 1
METHOD_NAMES = {METHOD_LZMA: "lzma", METHOD_BZIP2: "bzip2"}
# bzip2's level: the largest block (900 kB), which no blob here fills more than once.
BZIP2_LEVEL = 9
NAME_BYTES = 12
# LZMA2's smallest dictionary, and the preset every blob is compressed with.
MIN_WINDOW = 4096
PRESET = 9 | lzma.PRESET_EXTREME


class PackError(Exception):
    """A pack or an input that cannot be used; `problems` are sentences, each naming what is wrong."""

    def __init__(self, problems):
        self.problems = [problems] if isinstance(problems, str) else list(problems)
        super().__init__("; ".join(self.problems[:3]))


# ---------------------------------------------------------------------------------------------------------------
# Writing.
# ---------------------------------------------------------------------------------------------------------------

def window_size(raw_size):
    """The LZMA window for a blob of `raw_size` bytes: the smallest power of two at or above it, and at least 4 KiB."""
    size = MIN_WINDOW
    while size < raw_size:
        size *= 2
    return size


def compress(raw, windowed=True):
    """The xz stream of `raw` (LZMA2, preset 9 extreme); with `windowed`, its dictionary is `window_size(len(raw))`,
    otherwise the preset's own (64 MiB)."""
    spec = {"id": lzma.FILTER_LZMA2, "preset": PRESET}
    if windowed:
        spec["dict_size"] = window_size(len(raw))
    return lzma.compress(raw, format=lzma.FORMAT_XZ, filters=[spec])


def compress_bzip2(raw):
    """The bzip2 stream of `raw`, at BZIP2_LEVEL."""
    return bz2.compress(raw, BZIP2_LEVEL)


def compress_with(method, raw, windowed=True):
    """The bytes of `raw` compressed by `method` (a METHOD_ code); an unknown method is refused."""
    if method == METHOD_LZMA:
        return compress(raw, windowed)
    if method == METHOD_BZIP2:
        return compress_bzip2(raw)
    raise PackError(f"there is no compression method {method}")


def compress_smallest(raw, windowed=True):
    """(method, bytes) of the smaller of `raw`'s two compressions, LZMA (`compress`) and bzip2 (`compress_bzip2`);
    LZMA when they are the same size. Both compressors are deterministic, so the same raw bytes choose the same way."""
    lzma_bytes, bzip2_bytes = compress(raw, windowed), compress_bzip2(raw)
    if len(bzip2_bytes) < len(lzma_bytes):
        return METHOD_BZIP2, bzip2_bytes
    return METHOD_LZMA, lzma_bytes


def assemble(magic, version, digest, count, blobs, windowed=True, methods=None, choose=None):
    """The bytes of a pack: the header, the directory, and the blobs, each compressed by the method that makes it smaller.
    `blobs` is [(name, raw, entry count)]. `methods` ({blob name: METHOD_ code}) forces a method for the blobs it names:
    for the test fixtures, and for a pack that decided its method by measuring (the braille tables are LZMA's). `choose`
    replaces compress_smallest for the blobs `methods` leaves open."""
    methods = methods or {}
    choose = choose or compress_smallest
    packed = [(methods[name], compress_with(methods[name], raw, windowed)) if name in methods else choose(raw, windowed)
              for name, raw, _ in blobs]
    offset = HEADER.size + DIRECTORY_RECORD.size * len(blobs)
    directory = b""
    for (name, raw, entry_count), (method, data) in zip(blobs, packed):
        directory += DIRECTORY_RECORD.pack(name.encode("ascii"), offset, len(data), len(raw), entry_count, method)
        offset += len(data)
    return HEADER.pack(magic, version, 0, digest, count, len(blobs)) + directory + b"".join(data for _, data in packed)


# ---------------------------------------------------------------------------------------------------------------
# Reading.
# ---------------------------------------------------------------------------------------------------------------

@dataclass
class Record:
    """One directory record: a blob's `name`, its place in the file (`offset`, `compressed`), its `raw` size, its entry
    `count`, and its `method`."""
    name: str
    offset: int
    compressed: int
    raw: int
    count: int
    method: int


@dataclass
class Directory:
    """A pack's header and directory: `digest` (the 32 bytes), `count` (the header's), and `records` in file order."""
    digest: bytes
    count: int
    records: list


def read_directory(data, magic, version):
    """The header and directory of the pack `data` (bytes), checking the magic, the version, the flags, the directory's
    bounds, and that each blob lies inside the file. Raises PackError on the first thing wrong. A blob's bytes are
    decoded by `decode_raw`."""
    if len(data) < HEADER.size:
        raise PackError("the pack is shorter than its header")
    found_magic, found_version, flags, digest, count, blob_count = HEADER.unpack_from(data)
    if found_magic != magic:
        raise PackError(f"the magic is {found_magic!r}, not {magic!r}")
    if found_version != version or flags != 0:
        raise PackError(f"the version is {found_version} with flags {flags}, not {version} with none")
    if len(data) < HEADER.size + blob_count * DIRECTORY_RECORD.size:
        raise PackError("the directory is cut short")
    records = []
    for index in range(blob_count):
        raw_name, offset, size, raw_size, entry_count, method = DIRECTORY_RECORD.unpack_from(
            data, HEADER.size + index * DIRECTORY_RECORD.size)
        name = raw_name.rstrip(b"\0").decode("ascii", "replace")
        if offset + size > len(data):
            raise PackError(f"blob {name} runs past the end of the file")
        records.append(Record(name, offset, size, raw_size, entry_count, method))
    return Directory(digest, count, records)


def decode_raw(name, data, raw_size, method=METHOD_LZMA):
    """The raw bytes of the blob `name` from its compressed bytes `data` (compressed by `method`), which must decode to
    exactly `raw_size` bytes. (The output is capped at one byte more than `raw_size`, so a hostile blob cannot grow
    without limit.) An unknown method is refused."""
    if method == METHOD_LZMA:
        decoder = lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
    elif method == METHOD_BZIP2:
        decoder = bz2.BZ2Decompressor()
    else:
        raise PackError(f"blob {name} uses compression method {method}, which this tool does not know")
    try:
        raw = decoder.decompress(data, max_length=raw_size + 1)
    except (lzma.LZMAError, OSError, ValueError) as error:
        # bz2 reports damage as OSError ("Invalid data stream"), lzma as LZMAError.
        raise PackError(f"blob {name} does not decode: {error}")
    if len(raw) != raw_size or not decoder.eof:
        raise PackError(f"blob {name} decodes to a different size than the {raw_size} bytes its directory gives")
    return raw
