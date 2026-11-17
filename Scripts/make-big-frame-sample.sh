#!/bin/sh
# make-big-frame-sample.sh: makes TestData/format-samples/ffmpeg-edge/flac-7.1-24bit-65535.mka
# (FU-FFMPEG2), the sample whose one decoded frame is larger than a PCM record may be: FLAC in
# Matroska, 7.1 (8 channels), 24 bits, 8,000 Hz, 16.5 s in blocks of 65,535 samples (FLAC's
# most), so each of the two full blocks decodes to 2,097,120 bytes in the FFmpeg session's
# 32-bit form, past TMFF_MAX_PCM_RECORD_BYTES (1 MB), and must be split across PCM records
# (TextMouthFFmpeg/Session/session.c, make_pcm). Each channel holds one constant value (the
# channel's number from 1 to 8 times 0.01 of full scale), which FLAC stores in a few bytes, so
# the sample is under 1 KB, and a split that loses or repeats a sample puts a channel's value in
# another channel's place, which the test sees.
#
# Needs an ffmpeg with its own FLAC encoder (Homebrew's has it); it only makes the file, which
# TextMouth reads with its own bundled FFmpeg, never with this one.
#
# The bytes differ from run to run (Matroska writes a random segment UID); the sound is the same.
# Usage: Scripts/make-big-frame-sample.sh FOLDER   (a new, empty one; the sample goes in it)
set -e
folder="$1"
if [ -z "$folder" ]; then
    echo "usage: $0 FOLDER" >&2
    exit 1
fi
mkdir -p "$folder"
cd "$folder"
ffmpeg_tool=ffmpeg
"$ffmpeg_tool" -hide_banner -loglevel error -y \
    -f lavfi -i "aevalsrc=0.01|0.02|0.03|0.04|0.05|0.06|0.07|0.08:s=8000:d=16.5:c=7.1" \
    -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 -frame_size 65535 -strict -2 \
    flac-7.1-24bit-65535.mka
