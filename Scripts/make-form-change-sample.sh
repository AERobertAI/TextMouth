#!/bin/sh
# make-form-change-sample.sh: makes TestData/format-samples/mka/mp3-form-changes.mka (FU-FFMPEG2), and
# TestData/format-samples/ffmpeg-edge/mp3-ends-in-a-changed-form.mka (its first two stretches only),
# the sample of sound that changes its form partway: three stretches of MP3 of one second each,
# 22,050 Hz mono (440 Hz), 44,100 Hz stereo (880 Hz), and 22,050 Hz mono (660 Hz), joined byte
# for byte and stored in Matroska without encoding them again. A decoder (FFmpeg's mp3float)
# gives the rate and channels of each stretch as it reads it, which is what joined recordings
# do to the FFmpeg session (TextMouthFFmpeg/Session/session.c), which converts every later frame
# to the first stretch's rate and channels.
#
# Needs an ffmpeg with LAME (Homebrew's has it); it only makes the file, which TextMouth
# imports with its own bundled FFmpeg, never with this one. Writes q1.mp3, q2.mp3, q3.mp3,
# joined.mp3, and the sample into the folder named by the first argument (a new, empty one).
#
# The bytes differ from run to run (Matroska writes a random segment UID); the sound is the same.
# Usage: Scripts/make-form-change-sample.sh FOLDER
set -e
folder="$1"
if [ -z "$folder" ]; then
    echo "usage: $0 FOLDER" >&2
    exit 1
fi
mkdir -p "$folder"
cd "$folder"
ffmpeg_tool=ffmpeg
common="-hide_banner -loglevel error -y"
# No Xing header or tags, so every packet of each file is sound, and no packet is refused.
mp3="-c:a libmp3lame -write_xing 0 -id3v2_version 0 -write_id3v1 0"
"$ffmpeg_tool" $common -f lavfi -i "sine=frequency=440:duration=1:sample_rate=22050" -ac 1 $mp3 -b:a 24k q1.mp3
"$ffmpeg_tool" $common -f lavfi -i "sine=frequency=880:duration=1:sample_rate=44100" -ac 2 $mp3 -b:a 64k q2.mp3
"$ffmpeg_tool" $common -f lavfi -i "sine=frequency=660:duration=1:sample_rate=22050" -ac 1 $mp3 -b:a 24k q3.mp3
cat q1.mp3 q2.mp3 q3.mp3 > joined.mp3
"$ffmpeg_tool" $common -i joined.mp3 -c copy mp3-form-changes.mka
# The second sample ends in a stretch of another form than the first, which the session drains from its
# resampler at the end: the first two stretches only (23,616 and 23,040 frames at 22,050 Hz in all).
cat q1.mp3 q2.mp3 > joined-ends-changed.mp3
"$ffmpeg_tool" $common -i joined-ends-changed.mp3 -c copy mp3-ends-in-a-changed-form.mka
