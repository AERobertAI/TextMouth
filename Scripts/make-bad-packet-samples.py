#!/usr/bin/env python3
"""make-bad-packet-samples.py: makes the two samples of undecodable packets in
TestData/format-samples/ffmpeg-edge/ (FU-FFMPEG2), for the tests of the FFmpeg session's decoder
error bound (TextMouthFFmpeg/Session/session.c, MAX_ERRORS_IN_A_ROW: 1,000).

Each is FLAC in Matroska, mono, 16 bits, 8,000 Hz, 1,400 packets of 16 samples (2.8 s), made of a
constant level, which FLAC stores in 12 bytes a packet. In each, a run of packets in the middle
(from the 101st) has the first byte of its FLAC frame, the sync code's 0xFF, set to 0x00, so the
decoder refuses each of them (an invalid sync code) and the container is unchanged:
  flac-900-bad-packets.mka    900 refused packets, fewer than the bound
  flac-1200-bad-packets.mka   1,200 refused packets, more than the bound
  flac-all-bad-packets.mka    every one of the 1,400 refused (from the first packet): no sound at all

Needs an ffmpeg and ffprobe (Homebrew's); they only make the samples. The damaged samples are
read only by TextMouth's own bundled FFmpeg, and only on GitHub's runners (a damaged file could
crash the helper, which the development Mac never risks): do not run them here.

Usage: python3 -I -B Scripts/make-bad-packet-samples.py FOLDER   (a new, empty one)
"""
import subprocess
import sys
from pathlib import Path

# Each sample: the index of its first bad packet, and how many bad packets it has.
SAMPLES = {
    "flac-900-bad-packets.mka": (100, 900),
    "flac-1200-bad-packets.mka": (100, 1200),
    "flac-all-bad-packets.mka": (0, 1400),
}
# Bytes between a packet's position (ffprobe's pos: just past its block's id and size) and its
# payload: the block's track number (1 byte), timecode (2), and flags (1).
BLOCK_HEADER = 4


def run(command):
    """Runs `command` and returns its standard output, or stops the script with its error."""
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        sys.exit(f"{command[0]} failed: {result.stderr.strip()}")
    return result.stdout


def main(folder):
    """Makes the base file and the two damaged copies in `folder`."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    base = folder / "base.mka"
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "aevalsrc=0.1:s=8000:d=2.8:c=mono",
         "-c:a", "flac", "-sample_fmt", "s16", "-frame_size", "16", "-strict", "-2", str(base)])
    # Where each packet's block is in the file: one "pos=" line for each packet.
    listing = run(["ffprobe", "-hide_banner", "-loglevel", "error", "-show_entries", "packet=pos", "-select_streams", "a",
                   "-of", "default=nw=1", str(base)])
    positions = [int(line.split("=")[1]) for line in listing.splitlines() if line.startswith("pos=")]
    assert len(positions) == 1400, len(positions)
    original = base.read_bytes()
    for name, (start, count) in SAMPLES.items():
        damaged = bytearray(original)
        for position in positions[start:start + count]:
            assert damaged[position + BLOCK_HEADER] == 0xFF, "not a FLAC frame's sync code"
            damaged[position + BLOCK_HEADER] = 0x00
        (folder / name).write_bytes(bytes(damaged))
        print("made", folder / name)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
