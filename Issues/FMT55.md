---
id: FMT55
title: The iPhone converts the audio the Mac converts with Apple's converter (Ogg, Opus, AC-3, AMR, MP2, CAF, and the rest)
kind: format
status: open
priority: P2
platform: iphone
assignee:
created: 2026-11-17
updated: 2026-11-17
found-by: phoneffmpeg
branch:
merged:
reason:
related: FMT54
docs:
labels:
---

## Description

**What's missing.** Since FMT54, the iPhone converts the formats only FFmpeg reads, as the Mac does. It still refuses the audio the Mac converts with Apple's converter, afconvert: Ogg, Opus, AC-3, AMR, MP2, CAF, and the rest of `ImportAudioConverter.convertedExtensions`. The iPhone has no helper programs, so it says "Add it on your Mac, then send the book here." (`PhoneImportRefusal.convertedAudio`).

**The goal.** Parity: the user wants the iPhone at or near the Mac's features (November 16, 2026).

**Ways to do it.**
- **The in-app FFmpeg.** Its build already has the Ogg demuxer and the Vorbis, Opus, FLAC, and AC-3 decoders: an Ogg Vorbis file named .mka converts today.
- **AudioToolbox.** iOS has Apple's own converter API, which afconvert itself uses on the Mac.

Choose per format, and say why.

**Limits.**
- Measure the iPhone app's size before and after (`make ios-size`). The limit is 30 MB, and 40 MB strict; it is 16.1 MB with FMT54.
- Each format must import to the same book as on the Mac.

**From** phoneffmpeg's question 4 (November 17, 2026). The review judged that answer sound and asked for the size to be measured first.

## Comments
