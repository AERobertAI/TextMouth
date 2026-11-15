# Audio formats macOS can't read: smaller ways than ffmpeg (research, November 15, 2026)

Your request: "Have agents research to see if there are any smaller solutions to convert them or to have a custom converter like rtf doc etc."

The formats are WMA, WavPack, TTA, Monkey's Audio (APE), and Speex, which neither macOS nor iOS decodes.
The October research (`FORMATS-RESEARCH-2026-10-17.md`) offered ffmpeg for all five: the one Homebrew installs (FMT31), or one built into TextMouth at about 2.1 MB (FMT50).

How this was researched:
- Each licence was read from the project's own licence file or site.
- Four decoders were downloaded from their official sources, compiled for arm64 at `-Os`, and run on test files made here, each run a child process with a time limit.
- A TTA decoder was written in Swift as a prototype, to measure what a reader of TextMouth's own costs.
- No code of FFmpeg, Rockbox, libtta, or any other GPL or LGPL project was read.
- "Measured" marks a number from this Mac today, and "estimate" marks a judgment.

## The answer in short

- **Four of the five formats need no ffmpeg.**
  WavPack, TTA, Monkey's Audio, and Speex each have a BSD-licensed decoder by the format's own authors.
- **All four together are smaller than the smallest ffmpeg.**
  Linked as decoders only, they add 216 kB (measured), about a tenth of the 2.1 MB bundled ffmpeg.
- **A reader of TextMouth's own is practical for the three lossless formats.**
  - The Swift TTA prototype is 275 lines, gives the source's samples back exactly, and decodes 250 to 1,260 times faster than playback (measured).
  - A lossless format proves its own decoder: the decoded samples must equal the encoder's input, bit for bit, with no other decoder needed.
  - An own reader runs inside the app, so it works on the iPhone, where no helper program can run.
- **WMA is the exception.**
  - No decoder under a permissive licence was found for any of its five codecs.
  - Microsoft never published the codecs' formats, so a reader of TextMouth's own would have nothing lawful to follow.
  - ffmpeg stays the only route, and FMT31 (the installed ffmpeg) costs nothing.
- **Recommended:**
  1. own Swift readers for TTA, WavPack, and Monkey's Audio, in that order;
  2. WMA through the installed ffmpeg (FMT31), with a sentence for copy-protected files;
  3. Speex through FMT31 too, since it is rare, or libspeex in a helper if it should work without Homebrew;
  4. FMT50, the bundled ffmpeg, only if WMA and Matroska must work without Homebrew.

## How common each format is in audiobooks

None of the five is a format audiobooks are published in today.
WMA is the one a listener is likely to hold; the other four reach TextMouth mostly as old CD rips and voice recordings.

| Format | Where the files come from | In audiobooks |
|---|---|---|
| WMA 2 (WMA Standard) | Windows Media Player's default when ripping a CD through the 2000s; voice recorders; old downloads | The common one: ripped audiobook CDs, and library loans before 2015 |
| WMA Pro, Lossless, Voice | Windows Media Player's lossless option; low bit rate speech streams | Rare |
| Monkey's Audio | Whole-CD rips with a cue sheet, widely shared on Chinese-language forums | Rare; radio-drama and audiobook CDs kept as one file with a cue sheet |
| TTA | The same kind of whole-CD rip, mostly from East Asia, 2005 to about 2012 | Rare |
| WavPack | Archival rips, and some audio editors' exports | Rare |
| Speex | Voice recorders, voice-over-IP recordings, old low bit rate speech | Rare; Xiph calls it obsolete, replaced by Opus |

- OverDrive, which supplies most United States libraries, sold audiobooks as copy-protected WMA until it moved to MP3 in 2014 and removed the WMA titles in 2015.
  Nothing decodes those files without their licence, so TextMouth can only refuse them clearly.
- The Monkey's Audio claim rests on one low-authority site and on common report; no usage figure was found.
- Musepack is a lossy music format of the same years with a BSD decoder (libmpcdec), and no sign of use in audiobooks was found, so it is left to FMT31.

## What each decoder adds

Each library was compiled with Xcode's clang for arm64, macOS 14.0, at `-Os`.
"Objects" is the sum of every object file's code and data.
"Linked" is what a decode-only use adds: a small harness that calls only the decoding functions, linked with `-dead_strip` and stripped, less the same harness with no decoder.

| Decoder | Objects | Linked, decode only |
|---|---|---|
| TTA Hardware Players Library 1.2 | 9,681 B | 9,664 B |
| libwavpack 5.9.0, with DSD and WavPack 3 files | 141,492 B | 52,527 B |
| libwavpack 5.9.0, WavPack 4 and 5 samples only | 112,931 B | 29,999 B |
| Monkey's Audio SDK 13.47 | 189,443 B | 112,280 B |
| libspeex 1.2.1, floating point | 70,560 B | 63,817 B |
| libspeex 1.2.1, fixed point | 75,450 B | 69,299 B |
| The Swift TTA prototype, a whole command-line tool | | 20,309 B |

- The four smallest builds together are 215,760 bytes linked, or 238,288 with WavPack's DSD and old files.
- libspeex barely shrinks when linked because its mode tables point at the encoder's functions too.
- These are bytes of code and constants; inside the app they join its one binary, with no file of their own.

## What the decoders did with test files

Each harness decoded files encoded from synthetic recordings (tones under a speech-like envelope, plus filtered noise).

| File | Result | Speed against playback |
|---|---|---|
| TTA, 16-bit stereo 44.1 kHz, C library | identical | 526 times |
| TTA, the same file, Swift prototype | identical | 326 times |
| TTA, 24-bit stereo 48 kHz, C and Swift | identical | 430 and 253 times |
| TTA, 16-bit mono 22.05 kHz, C and Swift | identical | 2,020 and 1,261 times |
| WavPack, 16-bit stereo, fast to very high | identical | 454 to 243 times |
| WavPack, hybrid with its correction file | identical | 247 times |
| WavPack, hybrid alone (lossy) | decodes, no reference | 359 times |
| WavPack, 24-bit stereo 48 kHz, fast to very high | identical | 287 to 106 times |
| Monkey's Audio, 16-bit stereo: Fast, Normal, High | identical | 498, 390, 372 times |
| Monkey's Audio, 16-bit stereo: Extra High, Insane | identical | 198, 65 times |
| Monkey's Audio, 24-bit stereo 48 kHz: Fast to Insane | identical | 340 to 56 times |
| Speex, 8 kHz, 16 kHz, and 32 kHz mono, and 16 kHz stereo | within 3 of `speexdec` (5 in stereo) | 3,077 to 1,439 times |

- All 51 lossless decodes were identical, in every mode and level tried, by both WavPack builds.
- The repository's own `tta/tones.tta` and `wv/tones.wv`, made from one recording, decoded to the same digest by three decoders (41daa138…).

- The WavPack and Monkey's Audio files were written by those projects' own tools, built here from the same downloads; the TTA files by the installed ffmpeg; the Speex files by Homebrew's `speexenc`.
- "Identical" means the MD5 of the decoded samples equals the MD5 of the source WAV's samples.
- For Speex, which is lossy, the comparison is with Homebrew's `speexdec`.

## WMA: the codecs

| Codec | Format tag | Since | Limits | Permissive decoder | Public format |
|---|---|---|---|---|---|
| WMA 1 | 0x0160 | 1999 | stereo, 48 kHz | none found | no |
| WMA 2 (WMA Standard, versions 7 to 9) | 0x0161 | 1999 | stereo, 48 kHz | none found | no |
| WMA Pro | 0x0162 | 2003 | 8 channels, 96 kHz, 24 bits | none found | no |
| WMA Lossless | 0x0163 | 2003 | 6 channels, 96 kHz, 24 bits | none found | no |
| WMA Voice | 0x000A | 2003 | mono, 22.05 kHz, 20 kbit/s | none found | no |

- **Decoders.**
  FFmpeg decodes all five, from reverse engineering, under the LGPL 2.1 or later.
  Every other open decoder found is a copy of FFmpeg's (Rockbox's and DeaDBeeF's, both GPL or LGPL) or a wrapper around Windows' own (NAudio.Wma, MIT, Windows only).
  Microchip's and SPIRIT's are closed and sold to Microsoft's licensees.
- **A reader of TextMouth's own.**
  Microsoft has published no description of any WMA codec; Wikipedia says of WMA Lossless that its details "have never been publicly documented".
  The MultimediaWiki page on WMA is, in its own words, "random notes", with table names and sizes but no table contents.
  The only complete description is FFmpeg's source, which the project's rule forbids reading, so a WMA reader of TextMouth's own is ruled out.
- **Size through ffmpeg.**
  The October measurement put the WMA decoders and the ASF reader at 83,808 bytes of a 2.1 MB ffmpeg, whose fixed part (the tool, MP4, AAC, MP3) is 1.93 MB.
  An ffmpeg cut down to WMA alone, writing plain samples for Apple's encoder, would be an estimated 1.0 to 1.3 MB; it was not built.
- **Copy protection.**
  A protected file carries a Content Encryption object in its header, which a few lines of code can see before any decoder runs.
- **Patents.**
  WMA 1 and 2 date from 1999, and the others from 2003, so patents filed for them would have run out by about 2019 and 2023 (an estimate from the 20-year term, not a search).

## WMA: the ASF container

- A WMA file is an Advanced Systems Format file: a header of objects, each a 16-byte identifier and a 64-bit size, then data packets.
- A probe of 121 lines of Python (`asf_probe.py`) read this from the repository's `wma/tones.wma` (measured): the codec (format tag 0x0161), 1 channel, 22,050 Hz, 32,000 bit/s, 3.000 seconds, the title, and the author.
- **Tags:** the Content Description object (title, author, copyright, description) and the Extended Content Description object (`WM/AlbumTitle`, `WM/Genre`, `WM/Year`, `WM/TrackNumber`, and the rest), all UTF-16.
- **Chapters:** the Marker object, a list of names with times in units of 100 nanoseconds.
  The probe reads it, but no sample with markers was at hand.
- **What TextMouth needs of it:** the sniff (the header's identifier), the codec (lossless goes to Apple Lossless, the rest to AAC), and the protection check.
  ffmpeg reads the packets, and copies tags with `-map_metadata`.
- **The specification** is Microsoft's (revision 01.20.03, December 2004).
  Wikipedia reports that its licence does not allow distributing source code, and that a patent on ASF error correction ran until August 10, 2019.
  The licence text itself was not read today; see the questions.

## WavPack

| | |
|---|---|
| Decoder | libwavpack 5.9.0 (January 18, 2026), by David Bryant, BSD 3-clause |
| Source | https://github.com/dbry/WavPack/releases/tag/5.9.0 |
| Format | Public: `WavPack5FileFormat.pdf`, in the release's `doc` folder |
| Modes | Lossless; hybrid (a lossy `.wv` alone, or lossless with its `.wvc` correction file beside it); 32-bit float; DSD; many channels |
| Container | Its own blocks, each with a 32-byte header starting `wvpk` |
| Tags | APEv2 at the file's end (ID3v1 also) |
| Chapters | A `Cuesheet` item in the APEv2 tag, or a `.cue` file beside it |
| Self-check | A CRC in every block, and an optional MD5 of the samples |

- **Safety.** OSS-Fuzz fuzzes libwavpack; its reports of 2020 and 2025 are mostly in the DSD path, which TextMouth can leave out.
- **Smaller builds.** Leaving out DSD and WavPack 3 files (`ENABLE_DSD`, `ENABLE_LEGACY`) gives the smaller size in the table.
  wavpack.com also offers a "tiny decoder" (4.40) and ports to Java and C# by Peter McQuillan; their licences were not read.
- **A reader of TextMouth's own.**
  The decoding path for WavPack 4 and 5 samples is about 6,200 lines of C in 11 files, tags included (counted).
  A Swift reader would be an estimated 2,500 to 3,500 lines; hybrid, float, and many channels are most of the difficulty.
- **A hybrid file without its correction file** decodes to lossy audio, so it becomes AAC; with the `.wvc` it is lossless.

## TTA (True Audio)

| | |
|---|---|
| Decoder | TTA Hardware Players Library 1.2 (2004), by Alexander Djourik and Pavel Zhilin, BSD 3-clause |
| Source | https://sourceforge.net/projects/tta/files/tta/ttalib-hwplayer/ |
| Not usable | libtta 2.3 (2015), the current library: the project says its libraries are LGPL; it was not downloaded |
| Format | Public for the layout: https://tta.sourceforge.net/en/tta-format-description/ ; the algorithm is only in the code |
| Modes | 8 to 24 bits, any channels; a password-protected form (format 2), to refuse |
| Container | A 22-byte header starting `TTA1`, a seek table, then frames of 256/245 of a second |
| Tags | ID3v2 at the start; ID3v1 or APEv2 at the end |
| Chapters | A `.cue` file beside it, or a cue sheet in the APEv2 tag |
| Self-check | CRC-32 after the header, the seek table, and every frame |

- The BSD library is a player for small devices: it is 711 lines, keeps its state in globals, and refuses sample rates outside a list of nine (8,000 and 11,025 Hz among those refused).
  It is a map, not a library to ship.
- The whole algorithm is a Rice decoder, an adaptive filter of order 8, and a fixed first-order predictor: about 150 lines of that file.
- TTA2 has been "in development" on the project's site for years, and no file of it was found.

## Monkey's Audio (APE)

| | |
|---|---|
| Decoder | Monkey's Audio SDK 13.47 (November 13, 2026), by Matthew T. Ashland, BSD 3-clause since version 10.18 (August 10, 2023) |
| Source | https://monkeysaudio.com/developers.html (`MAC_1347_SDK.zip`) |
| Format | No specification; the SDK is the definition |
| Levels | Fast, Normal, High, Extra High, Insane; decoding costs as much as encoding at each level |
| Container | A descriptor starting `MAC `, a header, a seek table, then frames |
| Tags | APEv2 at the file's end, the tag format this project created |
| Chapters | A `.cue` file beside it (the usual form), or a cue sheet in the tag |
| Self-check | A CRC in every frame, and an MD5 of the whole file in the descriptor |

- **Speed is the format's cost.** Insane decodes at 56 to 65 times playback here, against 340 to 498 for Fast (measured).
  The SDK's arm64 build uses NEON for the long filters of the upper levels; plain Swift loops there would be an estimated 3 to 8 times slower, and SIMD types would close most of that.
- **Old files.** The SDK keeps a separate decoder for files older than version 3.93, about 2,900 lines in its `Old` folder (counted).
  Such files date from before about 2003 (from memory, not checked), so a reader of TextMouth's own could refuse them.
- **A reader of TextMouth's own.**
  The current decoding path is about 5,600 lines of C++ in 15 files (counted), tags and MD5 included.
  A Swift reader would be an estimated 2,500 to 3,500 lines.
- **Upkeep if vendored.** The SDK went from 11.81 to 13.47 in a year, mostly for its Windows program, and no fuzzing of it by OSS-Fuzz was found.
- An `.apl` file is a link to part of another file; TextMouth should refuse it, as it refuses Matroska's linked segments.

## Speex

| | |
|---|---|
| Decoder | libspeex 1.2.1 (June 11, 2022), by Jean-Marc Valin and Xiph.Org, BSD 3-clause (Xiph's wording) |
| Source | https://gitlab.xiph.org/xiph/speex ; the copy measured is GitHub's mirror, tag `Speex-1.2.1` |
| Format | The manual describes the codec and its bit allocation; the codebooks are only in the code |
| Modes | Narrowband (8 kHz), wideband (16 kHz), ultra-wideband (32 kHz); variable bit rate; intensity stereo |
| Container | Ogg: a `Speex   ` header packet of 80 bytes, a comment packet, then audio packets |
| Tags | The comment packet, laid out as Vorbis comments are |
| Chapters | None in practice |

- `OggHeaderReader` already reads Ogg pages and Vorbis comments, and today answers nil for Speex.
  Teaching it the Speex header (rate, channels, frames per packet) is about 40 lines (estimate).
- **A reader of TextMouth's own.**
  libspeex is about 11,000 lines of C without its tests, of which about 1,700 are codebook tables and a part is the encoder (counted).
  A Swift decoder would be an estimated 3,000 to 4,000 lines plus the tables.
  Speex is lossy, so the proof is harder than for the lossless three: see "How an own reader is proved".
- The library has an option to use FFTW, which is GPL; the build measured here leaves it out, and a decoder needs no FFT at all.
- The page's own verdict from October stands: Speex is obsolete and rare, so it is last in line.

## The Swift TTA prototype

`swift/tta_decode.swift` is a research harness, not app code.
It follows the BSD library's algorithm and the public format description.

- **Size:** 275 lines with comments, of which the decoder proper is about 200; the stripped tool is 20,309 bytes (measured).
- **Correct:** its output equals the source WAV's samples for all three test files, and equals the C library's for the repository's sample (measured).
  It passed on its first compile, which says how small the format is.
- **Fast enough:** 326 times playback for CD audio, 62 percent of the C library's speed, with no tuning (measured).
  A ten-hour audiobook in mono would take under a minute.
- **Checked reads:** every frame's CRC is verified, and a short or damaged file ends in a thrown error.
  It was not fuzzed.
- **Broader than its map:** it accepts any sample rate, where the BSD library refuses all but nine.
- **Missing for the app:** it reads the whole file into memory, and it reads no tags.

## How an own reader is proved

- **Lossless formats prove themselves.**
  Encode a known recording with the format's own encoder, decode it with TextMouth's reader, and compare the samples' digest with the recording's.
  No other decoder's output is needed, and no GPL code is read or even run.
- **The encoders are permissive too.**
  WavPack's `wavpack` and Monkey's Audio's `mac` built here from the same BSD sources and wrote today's test files at every level.
  TTA's own encoder is not permissive, so its files come from the installed ffmpeg, run as a program.
- **The formats carry their own checks.**
  Every frame of all three has a CRC, and WavPack and Monkey's Audio store an MD5, so a reader can also check any file a user brings.
- **The corpus** is small files in the repository's `TestData/format-samples`: each level or mode, 8, 16, and 24 bits, one, two, and six channels, a file shorter than one frame, and a file with tags and a cue sheet.
- **Hostile files.**
  Each reader takes bytes it cannot trust inside the app's own process, so every read must be checked and every sum must wrap.
  A test that flips bytes in each sample must end in a refusal and never in a trap, and decoding stops at the size the header promised.
- **Speex.**
  libspeex builds two ways: floating point, whose results differ in the last bit between compilers, and fixed point, which is whole-number arithmetic and exact.
  A Swift reader that follows the fixed-point path can be compared digest for digest with that build.
  Measured here: the floating-point build is within 3 of Homebrew's `speexdec` on every sample but not identical, and the fixed-point build differs from both by up to 2,998 of 32,768.

## Three ways to build a decoder in

| | Own Swift reader | The authors' C in a helper | ffmpeg |
|---|---|---|---|
| Size | TTA about 10 to 20 kB (measured); the others an estimated 30 to 80 kB each | 10 to 112 kB each (measured) | 0 installed; 2.1 MB bundled |
| iPhone | Yes | No: iOS starts no helper | No |
| Hostile files | Checked Swift, in the app | C, in a watched child process | C, in a watched child process |
| Work | Days to weeks each | About a day each | FMT31: about 450 lines |
| Upkeep | None: the formats are frozen | A rebuild at each security release | A rebuild at each ffmpeg security release |
| Licence | BSD notices in `Licenses` | BSD notices in `Licenses` | LGPL: source, notices, the legal checklist |

- The helper form is how liblouis is built in today: a static library that only `TextMouthBraille` links, because it is C that reads untrusted bytes.
- The own-reader form is how the Kindle reader was built: Swift of TextMouth's own that follows a permissive project closely and ships its licence.
- Either way the output is plain samples, which Apple's encoders turn into Apple Lossless or AAC in `.m4a`, as the Ogg conversion and the audio editor already do.
  Plain samples are safe to hand to Apple's frameworks inside the app.
- Tags and chapters then come from TextMouth's own readers: an APEv2 reader of about 150 lines serves WavPack, Monkey's Audio, and TTA, and the cue sheet reader is under way today (agent `cuesheets`).

## The proposals, ranked

1. **TTA, an own Swift reader.** Size S. The prototype is most of it.
   Remaining: reading in pieces instead of the whole file, the tags, tests, and the conversion's plumbing. Risk: low.
2. **WavPack, an own Swift reader** for WavPack 4 and 5 samples, lossless and hybrid, without DSD. Size M to L.
   Risk: medium; float and hybrid files need the most test files.
   The fallback, libwavpack in a Mac-only helper, is a day's work.
3. **Monkey's Audio, an own Swift reader** for files of version 3.93 and later. Size L.
   Risk: medium to high: no specification, five levels, and speed at the top two.
   The fallback is the SDK in a Mac-only helper.
4. **WMA through the installed ffmpeg (FMT31)**, cut down to WMA, Speex, Musepack, and the video containers' sound. Size M.
   Add the protection check and the codec's name to the refusal when ffmpeg is missing.
5. **Speex** through FMT31; or, if it should work without Homebrew, libspeex in a helper (a day), and an own reader only if iPhone users ask.
6. **FMT50, the bundled ffmpeg,** only for WMA and Matroska without Homebrew. Size L, 1.0 to 2.1 MB, a standing duty to rebuild.

Against the two open items:
- **FMT31** stays, smaller: it no longer needs to cover WavPack, TTA, or Monkey's Audio once their readers land.
- **FMT50** loses most of its reason: of the five formats here, only WMA would still need it.

## Questions for you

1. **Own readers or the authors' C?**
   Recommended: own Swift readers for TTA, WavPack, and Monkey's Audio, because they work on the iPhone, add no code that must be updated, and prove themselves exactly.
2. **Which first?**
   Recommended: TTA now (small), then WavPack, then Monkey's Audio; tell us if you hold APE files, since that would move it up.
3. **WMA without Homebrew?**
   Recommended: no; the installed ffmpeg only (FMT31), and FMT50 stays unbuilt until you want Matroska without Homebrew too.
4. **Speex.**
   Recommended: through FMT31 only, unless you have Speex files.
5. **The ASF specification's licence.**
   Wikipedia says it forbids distributing source code.
   Recommended: TextMouth reads only the header's identifiers, codec tag, and protection objects, which are widely documented facts, and leaves the packets to ffmpeg; have the licence read before any fuller ASF reader.
6. **Monkey's Audio files older than 2003.**
   Recommended: refuse them with a sentence, and add the old decoder only if such a file turns up.

## Not verified

- WMA Pro, Lossless, and Voice: no sample was decoded, and the format tags other than 0x0161 are from Microsoft's published constants, not from files.
- A WMA-only ffmpeg's size: an estimate; nothing of ffmpeg was built today.
- ASF markers as chapters: the probe's reading of the Marker object was not run on a file that has one.
- The ASF specification's licence text, and every patent date.
- How common each format is: no figures exist; the table is judgment from the sources below.
- The estimates of lines and of days for the WavPack, Monkey's Audio, and Speex readers, and of their compiled sizes.
- WavPack float, DSD, and multichannel files, 8-bit files of any format, and Monkey's Audio files older than 3.99: none was made or decoded.
- The Swift readers' speed beyond TTA, above all Monkey's Audio at Extra High and Insane.
- The BSD TTA library against files from TTA's own encoder: the test files came from ffmpeg's encoder.
- WavPack's tiny decoder and its Java and C# ports: neither downloaded nor their licences read.
- Whether libspeex is fuzzed by OSS-Fuzz, and any fuzzing of the four decoders here: none was run.

## Sources and files

Downloads, each in its own folder of `build/orchestrator/nov15/audiodecoders/downloads/` (gitignored), with SHA-256:
- `wavpack-5.9.0.tar.xz`, from the GitHub release: b5291bc4e6d69ebbd3da3800c5bf4a70f19bb92679b23e09b3b612c1e648d1ff
- `MAC_1347_SDK.zip`, from monkeysaudio.com: 6aec852ecf38ef91c0b323b83356f16cc6d485f1cc7a338151e60995a87e8166
- `ttalib-hwplayer-1.2.tgz`, from SourceForge's `tta` project: 2028573a43c91acf1a6048d1804f60e9a6d28f493cbcc0fed99895fdc88cf26f
- `speex-Speex-1.2.1.tar.gz`, GitHub's archive of the mirror's tag (commit b477035f): beaf2642e81a822eaade4d9ebf92e1678f301abfc74a29159c4e721ee70fdce0
  downloads.xiph.org's own tarball failed curl's certificate check, so the mirror was used.

The scripts, harnesses, and the Swift prototype are in `build/orchestrator/nov15/audiodecoders/scripts/` (gitignored): `build.py` (compile and measure), `run_tests.py` (encode, decode, compare), `compare_pcm.py`, `asf_probe.py`, and `swift/tta_decode.swift`.
The compiles and decodes ran directly, without the heavy-work lock, as the orchestrator allowed for light probes; each took under a minute.

Pages read:
- https://monkeysaudio.com/license.html and https://monkeysaudio.com/developers.html
- https://tta.sourceforge.net/en/tta-format-description/ and https://tta.sourceforge.net/en/tta-implementation/
- https://www.wavpack.com/downloads.html
- https://en.wikipedia.org/wiki/Windows_Media_Audio , https://en.wikipedia.org/wiki/Advanced_Systems_Format , and https://en.wikipedia.org/wiki/Monkey%27s_Audio
- https://wiki.multimedia.cx/index.php/Windows_Media_Audio
- https://slj.com/story/overdrive-announces-move-to-all-mp3-audiobooks (OverDrive leaving WMA)
- https://osv.dev/vulnerability/OSV-2025-108 (OSS-Fuzz on WavPack)
- The Speex manual (`doc/manual.pdf` in the release) and RFC 5574.
- `Scripts/agents/briefs/2026-10-17/formats/measurements.md` (the October ffmpeg measurement).
