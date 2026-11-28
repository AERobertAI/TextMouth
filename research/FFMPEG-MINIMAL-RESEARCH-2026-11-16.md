# A minimal FFmpeg built into TextMouth (research, November 16, 2026)

Your questions: "How much would a minimal inclusion of ffmpeg need? Doesn't iOS not support it or is that only for external stuff... how is ffmpeg licensed, like could you do the same thing as with the html parser and take out parts we don't need for the compile?"

Today the Mac converts WMA, Speex, Musepack, WebM, Matroska, RealAudio, and the sound of AVI, WMV, FLV, and MKV videos by running Homebrew's ffmpeg as a watched child process (`FFmpegAudioConverter`), and the iPhone refuses those files (`PhoneImportRefusal`).

How this was researched:
- FFmpeg 9.0.2 (September 18, 2026), the newest release, was downloaded from ffmpeg.org, and its signature checked against FFmpeg's key (fingerprint FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8), fetched both from ffmpeg.org and from the Ubuntu keyserver.
- It was built on this Mac with Xcode 26.0.1 through the heavy-work lock, for the Mac (arm64, macOS 14.0), the iPhone (iOS 26.0), and the iPhone simulator.
- Only FFmpeg's documentation was read: `configure --help` and its lists, `LICENSE.md`, `COPYING.LGPLv2.1`, ffmpeg.org's pages, and the build's own output; no FFmpeg C source was read, and nothing of it is copied into TextMouth.
- The test harness is TextMouth's own C, calling only FFmpeg's documented public API.
- "Measured" marks a number from this Mac today, and "estimate" a judgment.
- The scripts are in `research/ffmpeg-minimal/`; the builds are in `build/orchestrator/nov16/ffmpeglib/` (gitignored).

## The answer in short

- **Size, built into the app** (`--enable-small`, measured): WMA only adds 0.70 MB (696,304 bytes), WMA and WebM 0.94 MB (943,344), and everything the installed-ffmpeg path converts today 1.77 MB (1,766,688); without `--enable-small` each is a quarter to a third larger.
- **Against the limits:** the 18.5 MB Mac app stays under `make check`'s 20 MB with WMA only (19.2 MB) or WMA and WebM (19.5 MB as a helper program); parity passes it by 0.15 to 0.87 MB in every form; all are far under your 25 MB.
- **Why not smaller:** about 0.55 MB is FFmpeg's fixed part (libavutil and the cores of libavcodec and libavformat), which any set carries; WMA's five decoders are 123 KB and its demuxer 16 KB.
- **The October number** was real, but it measured the whole `ffmpeg` program with four WMA decoders, and was written down an hour after the October page; it is not what linking costs.
- **The iPhone:** iOS forbids starting a program ("On iOS, process spawning is unavailable", its SDK says), not FFmpeg; the libraries build for the iPhone and its simulator unchanged, add the same bytes, and call only libSystem.
  Apple's guidelines name no licence; their rule is that code stays inside the app's bundle, where Apple's own note puts frameworks; TestFlight follows the same guidelines.
- **The licence:** LGPL 2.1 or later in every set (configure's own words); static linking is allowed when the app's source lets anyone relink a changed FFmpeg, which TextMouth's public source does, as it does for LAME today.
- **Trimming:** yes, and FFmpeg's `configure` does it: parity compiles 383 of its libraries' 2,661 files; the best way in is a pinned release tarball built by a script, not a vendored copy.
- **Safety and upkeep:** built in, a decoder's bug runs inside TextMouth, so the Mac should keep a helper program; NVD lists 22 CVEs since 2016 in parity's parts (five still open in 9.0.2), 4 in WMA and WebM's, and 3 in WMA only's.
- **Recommended:** WMA and WebM, from a pinned FFmpeg 9.0 release, in a helper on the Mac and in the app on the iPhone; the installed ffmpeg keeps the rarer formats on the Mac.

## The October number, settled

The November 15 page cites "an October measurement" of 83,808 bytes for WMA in "a 2.1 MB ffmpeg" with a 1.93 MB fixed part; the October 17 page says a minimal ffmpeg's size "is not measured".
Both are true of their moment.
- The October page was written at 16:22 on October 17 (6b680b5d4), and your answers, among them "Try measuring it using a test build", were added at 17:22 (c6f63f149).
- The measurement your answer asked for was then made by agent `fmtmeasure` and recorded at 17:41 in `Scripts/agents/briefs/2026-10-17/formats/measurements.md` and the TODO (bae773405), never in the page.

It measured something other than what TextMouth would build in:
- the whole `ffmpeg` command-line program, with its own code, libavfilter's filter graph, libswresample, the AAC and ALAC encoders, and the MP4 writer, none of which an in-app decoder needs;
- four WMA decoders, not five: WMA Voice (`wmavoice`) was not in its list;
- "2.1 MB" was the build with link-time optimization (2,086,640 B), while the 1.93 MB fixed part and the 83,808 B were taken from the 2,400,768 B build without it.

So its numbers say what a bundled `ffmpeg` program costs, not what linking the libraries into the app costs; today's measurements, below, answer the second.

## How it was measured

The configure line of every build, with the set's components and the platform's compiler (this is set b's, for the Mac, at `--enable-small`; paths shortened to `SDK`):

```
configure --disable-everything --disable-autodetect --disable-network --disable-programs --disable-doc \
  --disable-avdevice --disable-swscale --disable-avfilter --disable-swresample \
  --enable-static --disable-shared --disable-debug \
  --cc="clang --target=arm64-apple-macos14.0 -isysroot SDK" --as="clang --target=arm64-apple-macos14.0 -isysroot SDK" \
  --sysroot=SDK --enable-small \
  --enable-demuxer=asf --enable-decoder=wmav1 --enable-decoder=wmav2 --enable-decoder=wmapro \
  --enable-decoder=wmalossless --enable-decoder=wmavoice
```

- This is the brief's base line, less `--prefix`, plus `--disable-debug` and four libraries left out: libavdevice, libswscale, and libavfilter always, and libswresample wherever the set has no Opus.
  TextMouth's own code would hand the samples to Apple's converter and encoder, as the Ogg conversion and the audio editor do.
- **Opus needs libswresample.**
  The first build of the parity set lost its Opus decoder, with configure's "WARNING: Disabled opus_decoder because not all dependencies are satisfied: swresample", so sets a, c, and d build libswresample too (that first build is kept as "parity without Opus").
- Every build checks that configure enabled each component asked for, and that every object file was built for its platform.
- No protocol is enabled: the harness reads the file through its own callbacks.
- The iPhone's builds add `--enable-cross-compile --target-os=darwin --arch=aarch64`, with `arm64-apple-ios26.0` or `arm64-apple-ios26.0-simulator` and Xcode's iPhone SDKs.
- **Bytes added:** `harness.c` compiled twice, without FFmpeg and with it, each linked as the Release app links (`-Os`, `-dead_strip`, `-no_exported_symbols`), stripped of every symbol, and signed; the difference between the two files.
  A library's `.a` size is not that number: the linker keeps only what the demuxers and decoders named reach.
- **Build time:** configure's and make's wall-clock seconds at `make -j4` on this 8-core Mac, shared with other agents, and make's processor seconds, which carry to another Mac.
- **Files compiled:** make's own lines, one for each file (CC for C, AS for assembly).
- `research/ffmpeg-minimal/build.py` ran every step; its records are `build.json` (with each build's whole configure line), `measure.json`, and `decode.json` in each build's folder.

## The sets

- **a. Parity**, what the installed-ffmpeg path converts today, from `FFmpegContainer.demuxer`, `FFmpegAudioConverter.isLossless`, `FFmpegImportPlanTests`, and the samples, plus each container's common codecs:
  - demuxers (8): `asf`, `matroska` (WebM too), `flv`, `avi`, `rm`, `mpc`, `mpc8`, `ogg`;
  - decoders (48):
    - the five WMA: `wmav1`, `wmav2`, `wmapro`, `wmalossless`, `wmavoice`;
    - `speex`, `mpc7`, `mpc8`, and RealAudio's `cook`, `sipr`, `atrac3`, `ralf`, `ra_144`, `ra_288`;
    - `aac`, `mp3float`, `mp2float`, `ac3`, `eac3`, `opus`, `vorbis`, `dca`;
    - `flac`, `alac`, `truehd`, `mlp`, and `tta`, `wavpack`, `ape` (inside Matroska);
    - PCM in 12 layouts, A-law, and μ-law;
    - the video files' `adpcm_ms`, `adpcm_ima_wav`, `adpcm_swf`, `nellymoser`, `gsm_ms`;
  - parsers (11): `aac`, `ac3`, `cook`, `dca`, `flac`, `gsm`, `mlp`, `mpegaudio`, `opus`, `sipr`, `vorbis`.
- **b. WMA only:** the `asf` demuxer and the five WMA decoders.
- **c. Parity without the video containers:** a less `avi` and `flv`, the five codecs only they carry, and the `gsm` parser (6 demuxers, 43 decoders, 10 parsers).
- **d. WMA and WebM:** `asf` and `matroska`, the five WMA decoders, `opus` and `vorbis`, and their parsers: WMA as the one format with no other way in, and WebM as the one you said you "see more" than the others.

## The size of each set on the Mac

Bytes each set adds to the stripped, dead-stripped harness, with the files compiled and the times (measured; arm64, macOS 14.0, `make -j4`):

| Set | `--enable-small` | Without it (`-O3`) | Files compiled: C, assembly | configure, make; make's processor time |
|---|---|---|---|---|
| a. Parity | 1,766,688 | 2,356,208 | 364, 19 | 13.7 s, 6.8 s; 25.4 s |
| b. WMA only | 696,304 | 859,920 | 200, 8 | 12.4 s, 3.5 s; 12.6 s |
| c. Parity without video containers | 1,700,800 | 2,274,000 | 354, 19 | 13.0 s, 6.9 s; 25.8 s |
| d. WMA and WebM | 943,344 | not built | 238, 12 | 12.2 s, 4.2 s; 15.3 s |

- The `-O3` builds took 12.1 to 13.8 s to configure and 4.1 to 8.7 s to make (14.7 to 32.5 s of processor time).
- `--enable-small` saves a fifth to a quarter: 589,520 bytes in parity, 163,616 in WMA only; it costs some decoding speed, which matters little in a one-time conversion (an estimate: decoding was not timed).
- Link-time optimization (`--enable-small --enable-lto`, parity) adds 1,683,840 bytes, 82,848 fewer; its objects are LLVM bitcode, which another Xcode's linker may not read, so it suits only libraries built by the same Xcode as the app.
- Opus, with the libswresample it needs, costs 115,344 bytes: the first build, without them, added 1,651,344.
- The video containers cost little: c is 65,888 bytes smaller than a.
- `.a` sizes are not the growth: parity's four libraries are 3,571,200 bytes, twice what the linker keeps.

What the Mac app would weigh, from its 18,463,201-byte Release build, against `make check`'s 20,000,000 bytes:
- in the app's process, at `--enable-small`: a 20,229,889 (229,889 over), c 20,164,001 (164,001 over), d 19,406,545, b 19,159,505;
- as a helper, whose whole program (52,128 bytes without FFmpeg) is added: a 20,282,017, c 20,216,129, d 19,458,673, b 19,211,633;
- parity with link-time optimization is still 147,041 over in the app's process; every set is far under your 25 MB.

## What the bytes are

The linker's map gives each object file's bytes, summed here by component (`linked_bytes_by_component` in `measure.json`).

Every set pays a fixed part first (measured, set b at `--enable-small`):
- of WMA only's 696,304 bytes, the five WMA decoders are 123,490 and the ASF demuxer 16,486, while libavutil (304,566), libavcodec's core (133,994), and libavformat's core (86,034) are 525 KB, three quarters of the whole;
- the fixed part's largest pieces are libavutil's transform code, shared by every decoder that uses an MDCT (the `tx` files, 175 KB), libavcodec's option and codec-description tables (65 KB), the pixel-format table (34 KB, linked though no picture is decoded), and the demuxing core (28 KB);
- the harness's own decoding code is 2.8 KB of the difference, and the linker's stubs and tables 7.6 KB, as TextMouth's own code around the libraries would be.

So no set can be much smaller than about 0.55 MB, and each format beyond adds its own decoder and demuxer.

In parity (set a, `--enable-small`), the fixed part grows to 625,118 bytes (libavutil 331,962, libavcodec's core 190,320, libavformat's core 102,836), and the rest is, in bytes (measured):
- DTS 176,053; RealAudio's six decoders 168,041; AAC 155,698; WMA's five 123,405;
- Vorbis 58,088; libswresample 49,436 and Opus 13,072; AC-3 and E-AC-3 41,679; Matroska 37,216; TTA, WavPack, and Monkey's Audio 36,077; MP3 and MP2 33,704;
- Speex 23,386; Ogg 22,688; Musepack 19,406 and its demuxers 5,111; FLAC 18,430; Flash video 17,426; ADPCM, Nellymoser, and GSM 16,912; AVI 16,664; TrueHD and MLP 16,528; ASF 16,486;
- RealMedia 11,175; the RIFF headers 7,969; ALAC 5,777; PCM 4,589; the speech-codec tools 3,428.

DTS, RealAudio, and AAC are 45 percent of what parity adds beyond the fixed part.
Apple's frameworks decode AAC, MP3, FLAC, ALAC, and PCM, and on the Mac AC-3, E-AC-3, and MP2 too (the October 17 page verified those three; the iPhone's were not tried), so a design that handed those packets to Apple would leave 259,877 bytes out of FFmpeg.

## The decode check

Each Mac build's harness decoded copies of the 13 samples of `TestData/format-samples` that `FFmpegImportRealTests` imports, and its samples were compared with those of the installed ffmpeg 7.1.1, run as a program with the same decoder forced (measured):
- **Identical to the bit:** WMA 1 and WMA 2 (the three WMA files and the WMV's sound), MP3 in AVI, AAC in Flash video, FLAC in Matroska, Vorbis in WebM, and RealAudio 14.4.
- **Identical after a lead:** 5.1 AC-3 in Matroska; ffmpeg 7.1.1 keeps 256 near-silent samples a channel at the start (the decoder's start-up delay, none above 0.0002) that 9.0.2 drops.
- **Within rounding:** Speex, within 0.0000038 of a peak of 0.57, and Opus, within 0.00000009; floating-point decoders built by two compilers.
- **Refused as they should be:** set d, which has no FLAC or AC-3 decoder, answered "no audio stream this build decodes" for those two Matroska files, which is where TextMouth's own refusal would go.
- **Chapters and tags come through the library:** the three chapters of each marked WMA, WMV, MKV, and MKA file ("Tone 880 Hz (café)" among them), the two of the two-track Matroska file, and every title and artist; these are what `-map_chapters` and `-map_metadata` carry today.
- **The track:** in the two-track Matroska file, FFmpeg's own choice (`av_find_best_stream`) was the English narration, the default track, which `FFprobeReport.chosenAudio`'s rule (the first default track, else the first) picks too.
- Not decoded, for want of a sample in `TestData/format-samples`:
  - WMA Pro, Lossless, and Voice; Musepack and its two demuxers; Cook, ACELP.net, ATRAC3, RealAudio Lossless, and 28.8;
  - MP2, E-AC-3, DTS, ALAC, TrueHD, MLP, PCM, ADPCM, Nellymoser, GSM, and TTA, WavPack, and Monkey's Audio inside Matroska.

## The iPhone: the builds

Parity built unchanged for iOS 26.0 with Xcode 26.0.1's SDKs, for the device and the simulator, each of its 383 objects marked for its platform (measured):
- it adds 1,766,688 bytes on the device and 1,766,640 on the simulator, as on the Mac; WMA only adds 696,304, and WMA and WebM 926,928 (943,296 on the simulator);
- the linked program imports 120 functions, all from libSystem (`otool -L` lists nothing else), and neither it nor the whole libraries import any function that starts a process (`fork`, `posix_spawn`, `system`, `popen`, the `exec` family) or loads code (`dlopen`, `dlsym`);
- libavutil's link line names CoreFoundation, CoreVideo, and CoreMedia, but the decode path calls none of them, and the harness links without them.

## The iPhone: what Apple's rules say

"Doesn't iOS not support it": iOS runs FFmpeg's libraries; what it refuses is starting another program, which is all TextMouth does with ffmpeg today.
- The iOS 26.0 SDK's own header says so: `system()` is marked `__IOS_PROHIBITED`, with the note "Use posix_spawn APIs or NSTask instead. (On iOS, process spawning is unavailable.)" (`usr/include/_stdlib.h`), and Foundation imports `NSTask` only on the Mac.
- So the installed-ffmpeg path can never reach the iPhone, while libraries linked into the app can.

The App Review Guidelines (today's, developer.apple.com/app-store/review/guidelines/) name no licence: neither "GPL", "LGPL", nor "open source" appears in their text.
The rules that apply are about code, not licences:
- 2.5.1: "Apps may only use public APIs and must run on the currently shipping OS."
- 2.5.2: "Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor may they download, install, or execute code which introduces or changes features or functionality of the app".
- 2.2, for TestFlight: "Any app submitted for beta distribution via TestFlight should be intended for public distribution and should comply with the App Review Guidelines."
- 5.2.1: "Don't use protected third-party material such as trademarks, copyrighted works, or patented ideas in your app without permission".

Dynamic frameworks are allowed when they ship inside the app: Apple's TN2435 says "A framework is a hierarchical directory that encapsulates a dynamic library ... Apps using frameworks need to embed the framework in the app's bundle."
A framework downloaded later would break 2.5.2; one in the bundle, signed with the app, does not.
Static libraries, as LAME already is in the iPhone app, raise no question under these rules.

Two more rules reach any C library:
- **Privacy manifests.**
  Apple's "Describing use of required reason API" says: "For each executable or dynamic library in an app that uses a required reason API, the bundle that includes the executable or dynamic library needs to include a privacy manifest file".
  Since May 1, 2024, apps that don't describe that use "aren't accepted by App Store Connect".
  The linked harness imports none of those APIs, on the iPhone or the Mac (measured); the only one the libraries call anywhere, `fstat`, is in libavutil's `file.o`, which the decode path never loads, so FFmpeg would add nothing to a manifest.
  The iPhone app has no `PrivacyInfo.xcprivacy` yet, whatever FFmpeg does.
- **Apple's list of SDKs that need their own manifest and signature** (developer.apple.com/support/third-party-SDK-requirements/) does not name FFmpeg.

Apple's standard licence for apps (the Licensed Application End User License Agreement) forbids reverse engineering "except ... to the extent as may be permitted by the licensing terms governing use of any open-sourced components included with the Licensed Application".
So it gives way to the LGPL's terms for FFmpeg (next section).

## The licence

FFmpeg is "licensed under the GNU Lesser General Public License (LGPL) version 2.1 or later", and becomes GPL only with `--enable-gpl` (ffmpeg.org/legal.html).
`LICENSE.md` lists the GPL files: x86 optimizations, build and test tools, and video filters, none of which an arm64 build without `--enable-gpl` compiles.
All 14 builds' configure summaries say "License: LGPL version 2.1 or later" (measured).

The LGPL 2.1's section 6 is what linking must meet, static or dynamic (`COPYING.LGPLv2.1` of the release):
> you may also combine or link a "work that uses the Library" with the Library ... and distribute that work under terms of your choice, provided that the terms permit modification of the work for the customer's own use and reverse engineering for debugging such modifications.

It then asks for a notice and a copy of the licence, and one of five things, of which two matter here:
> a) Accompany the work with the complete corresponding machine-readable source code for the Library ...; and, if the work is an executable linked with the Library, with the complete machine-readable "work that uses the Library" ... so that the user can modify the Library and then relink ...

> b) Use a suitable shared library mechanism ... one that (1) uses at run time a copy of the library already present on the user's computer system ... and (2) will operate properly with a modified version of the library, if the user installs one ...

- **Static linking** is 6(a), and TextMouth meets it as it does for LAME (`docs/developer/third-party-code.md`): the app's whole source is public under the MIT licence, so anyone can change FFmpeg and rebuild the app with `make build`.
- **Dynamic linking** is 6(b), FFmpeg's checklist's own choice, but an iPhone lets no user swap a library inside a signed app, so on the iPhone it gains nothing over 6(a) and costs a framework.
- **Version 3 must stay off.**
  `--enable-version3` would make it the LGPL 3, which also asks for the information a user needs to install a changed version on the device, something an App Store app cannot give; every set here is version 2.1.

ffmpeg.org's "License Compliance Checklist" ("not the only way to comply with the license, but we think it is the easiest"), item by item, with what TextMouth would do:
1. "Compile FFmpeg without "--enable-gpl" and without "--enable-nonfree"": done in every set.
2. "Use dynamic linking": the alternative 6(a) is used instead, as above.
3. "Distribute the source code of FFmpeg, no matter if you modified it or not", as a "tarball or a zip file", with "the configure line, in a text file added to the root directory": the unchanged release tarball and the script that records its configure line.
4. "Make sure the source code corresponds exactly to the library binaries": a pinned release, checked by its signature and SHA-256, with no changes ("git diff > changes.diff" would be empty).
5. "Host the FFmpeg source code on the same webserver as the binary": wherever a built app is offered (a GitHub release, the App Store page's own site), the tarball goes beside it, with the sentence the checklist gives for download pages.
6. "Mention "This software uses libraries from the FFmpeg project under the LGPLv2.1" in your program "about box"": TextMouth has no About text of its own yet.
   On the Mac a `Credits.rtf` would carry it (AppKit's About panel "looks for a file named "Credits.html", "Credits.rtf", and "Credits.rtfd""); on the iPhone, a line beside its licence notices.
7. "Mention in your EULA that your program uses FFmpeg under the LGPLv2.1" and "Remove any prohibition of reverse engineering from your EULA": TextMouth's own licence is MIT.
   On the App Store the standard licence gives way to open-source terms (above), and provides for "a Custom EULA" in its place if one is wanted.
8. "Do not misspell FFmpeg": the library is "FFmpeg"; the installed program keeps its command's name, "ffmpeg".
9. "Make sure your program is not using any GPL libraries": `--disable-autodetect` links no outside library at all.

The licence's text goes in `Licenses/FFmpeg` of both apps, as `Licenses/LAME` and `Licenses/liblouis` are today.
The libraries compile libjpeg's three DCT files, for which `LICENSE.md` says "you must credit the IJG in the documentation accompanying your program if you only distribute executables".
The decode path loads none of their objects (measured), so the apps need no IJG credit; a committed XCFramework or vendored source would hold them, and then the credit.

## Patents, as context

- FFmpeg's own answer to "Does FFmpeg use patented algorithms?" is "We do not know ... we have never read patents to implement any part of FFmpeg" (ffmpeg.org/legal.html).
- WMA 1 and 2 date from 1999 and WMA Pro, Lossless, and Voice from 2003; a patent filed then would have ended by about 2019 and 2023 at the 20-year term (an estimate, not a patent search, as on the November 15 page).
- AAC is still licensed by Via's pool (the October 17 page); the parity set holds FFmpeg's own AAC decoder, which a design that copies AAC into the `.m4a` as today, or hands it to Apple's decoder, would not need.
- MP3's, AC-3's, and E-AC-3's last patents have ended (the October 17 page); Opus, Vorbis, FLAC, Speex, WavPack, TTA, Monkey's Audio, and Musepack are royalty-free as far as known.
- RealAudio's Cook, ATRAC3, and ACELP.net date from the late 1990s; their status was not looked up.
- This is context, not legal advice; it bears on whoever distributes the app.

## Trimming, as with SwiftSoup: three ways to bring FFmpeg in

Yes, FFmpeg can be cut down as SwiftSoup was, and further: its own `configure` does the cutting, so nothing of its code is edited, and the libraries hold only the parts named.
- Parity compiles 383 of the 2,661 C and assembly files of its four libraries (14 percent), WMA and WebM 250, and WMA only 208 (measured).
- libavutil's 102 are the same in every set: `--disable-everything` trims decoders, demuxers, and parsers, not libavutil.
- **A trap for ii and iii:** configure writes its command line (`FFMPEG_CONFIGURATION`) and the install folder into `config.h`, absolute paths included.
  They reach the libraries, once in `libavutil.a` and four times in each platform's library of parity's XCFramework, but never the linked program (measured).
  So a committed `config.h` or binary must be configured with neutral paths, or it puts this Mac's home folder into the public repository, against the rule that no tracked file names one.

- **i. A pinned release tarball, built by a script at build time.**
  - Repository: the script and its pin (version, SHA-256, configure line), a few kilobytes; the 12,040,788-byte tarball is fetched once into `build/` (gitignored), or kept beside the source if builds must work offline.
  - Build time: configure takes 12 to 16 s and make 3.5 to 7 s a platform here (measured), about a minute for the Mac, the iPhone, and the simulator; the libraries are kept until the version, the configure line, or Xcode changes, so an ordinary build of the app pays nothing.
  - A new release: change the version and the SHA-256, check the signature, rebuild, and run the tests; minutes of work.
  - It fits how `make build` works: a step before `xcodebuild` writes the libraries into `build/`, and `project.yml` links them as it links LAME's.
- **ii. A vendored, trimmed source, compiled by `project.yml` as LAME is.**
  - Repository: every file the build compiled or included, from the compiler's own dependency lists (measured): 790 files, 10,420,407 bytes, for parity (387 C, 21 assembly, 382 headers); 541 files, 6,488,247 bytes, for WMA and WebM; 465 files, 5,489,136 bytes, for WMA only.
  - Plus the 10 files configure writes (104,812 bytes for parity), which differ by platform: the iPhone's `config.h` turns off three CPU-feature flags (`HAVE_ARM_CRC_INLINE`, `HAVE_DOTPROD_INLINE`, `HAVE_EOR3_INLINE`) that the Mac's and the simulator's turn on.
  - Build time: Xcode compiles the same files; make took 3.5 to 7 s at four jobs.
  - The catch: the copy is FFmpeg's source plus what `configure` wrote for one platform and one set (`config.h`, `config_components.h`, the component lists, the compiler flags).
  - So each new release or changed set means running a vendoring script again (configure for each platform, copy the files it compiled) and reviewing a diff of thousands of lines.
  - It suits LAME (one library, one `config.h` written by hand, unchanged since 2017); FFmpeg releases every few weeks or months.
- **iii. A committed prebuilt XCFramework, with its source and configure line published.**
  - Repository: parity's XCFramework for the Mac, the iPhone, and the simulator is 14,339,959 bytes, 5,700,047 compressed (measured); each FFmpeg update would add about as much again, since binaries compress poorly against each other (an estimate).
  - Build time: none.
  - A new release: run the script, commit the new binaries; each version stays in git's history for good, and a reviewer cannot read what changed.

Security upkeep is the same code, and so the same CVEs, in all three; what differs is how fast a fix lands: i in minutes, iii in minutes plus binaries in the history, ii in an hour or more of re-vendoring.

## Security upkeep: how often these parts get CVEs

The source is NVD's API (services.nvd.nist.gov, version 2.0, keyword "FFmpeg"), fetched today: 738 CVEs, 519 of them published since 2016.
A word match found 74 since 2016 naming a component of the parity set; each was then read by hand, since many name only the container an attack file came in ("a crafted AVI file" holding a video codec's bug) or FFmpeg's encoders and muxers, which no set compiles.
`research/ffmpeg-minimal/cve_tally.py` holds the reading (`REVIEWED`) and prints the counts.

CVEs since 2016 whose bug lies in code a set compiles (measured):
- **Set a, parity:** 22; by year 6 (2016), 3 (2017), 3 (2018), 1 (2021), 1 (2022), 2 (2024), 6 (2026); three rated high: CVE-2017-11399 (Monkey's Audio), CVE-2020-24995 (AAC), CVE-2026-125203 (Cook).
  By component: AVI demuxer 5, ASF demuxer 3, AAC decoder 2, Monkey's Audio decoder 2, Cook decoder 2, and one each for the GSM parser, the AC-3 parser, the RealMedia demuxer, the Ogg demuxer's Vorbis headers, Speex, Musepack SV7, the FLAC parser, and the Vorbis parser.
- **Set c, no video containers:** 16.
- **Set b, WMA only:** 3, all in the ASF demuxer (CVE-2017-14057 and CVE-2017-14223, both loops on a header that claims more than it holds, and CVE-2018-1999015, an out-of-bounds read); none in the five WMA decoders.
- **Set d, WMA and WebM:** 4, those three and the Vorbis parser's.
- Not counted: CVE-2025-22919 (an assertion "via opening a crafted AAC file", its component unnamed) and CVE-2026-125072 (a bug in the MP3 decoders' shared code, reached through the `mp3adu` decoder, which no set has).

What is open today:
- Six of the 22 were published on November 9, 2026; five of them say "FFmpeg through 9.0.2", so the newest release still has them: Monkey's Audio (gigabytes allocated), Musepack SV7 and Cook (reads past a buffer), the FLAC parser (unbounded recursion), and the Vorbis parser (CPU).
- FFmpeg's security page (ffmpeg.org/security.html, "maintained by the FFmpeg community") lists none of the November 9 CVEs yet, so no release is known to fix them; set b has none of them.
- FFmpeg's point releases come weeks or months apart (9.0 on August 4, 9.0.1 on August 12, 9.0.2 on September 18, none since; the dates of ffmpeg.org/releases/), each listing its fixes on the security page.
- CVEs are a floor: FFmpeg is fuzzed by OSS-Fuzz (`projects/ffmpeg` in google/oss-fuzz), whose findings are mostly fixed as ordinary commits (an inference; not counted).

The upkeep follows from that: whichever way FFmpeg comes in, it is rebuilt at each point release, and the CVEs naming its components are watched; the smaller the set, the fewer there are.

## Safety: a helper on the Mac, or in-process

Today a hostile file can take down only the watched ffmpeg or ffprobe (`WatchedProcess`: a time limit, a memory limit, a stall limit, and an output cap).
Built in, a decoder's bug runs inside whatever process links it.

- **The Mac app is not sandboxed** (`com.apple.security.app-sandbox` is false in `TextMouth/Resources/TextMouth.entitlements`), so a decoder bug exploited in its process could reach every file the user can.
- **A Mac helper** (say `TextMouthDecoder`, built as `TextMouthBraille` is) links the minimal libraries, reads one file, and writes plain samples and a line of tags and chapters to its output; the app runs it under `WatchedProcess` with today's limits, so a hang or crash costs one run.
  It can also end itself with `_exit` on a fatal signal, as the research harness does, so that a decoder crash should put no crash report on the screen (not tried: no crash may run on this Mac).
- **In-process** keeps what the import already applies, and adds what the library offers:
  - TextMouth's own sniff (`FFmpegContainer`) forcing the demuxer;
  - reading through TextMouth's own callbacks with no protocol compiled in, so FFmpeg can open no other file or address;
  - `av_max_alloc` capping any one allocation, and the output and length limits of `FFmpegAudioConverter`.
- **What in-process cannot add:** a time limit that stops a decoder looping inside one call, a memory limit for the whole decode, or survival of a crash.
- **The iPhone has no choice**: it starts no helper, so it runs the libraries in its process, where iOS's own sandbox limits a compromise to the app's container and the files the user gave it.

Recommended: the helper on the Mac, in-process on the iPhone, and the smallest set that covers the formats wanted, since every decoder left out is attack surface removed.

## The FU-FFMPEG items

The TODO's FU-FFMPEG item lists the ffmpeg import's leftovers; a built-in FFmpeg changes most of them:
- **Drop the "mpp" extension:** unchanged; it is a question of names.
- **Cap each tag passed to ffmpeg at 4 KB:** the command line goes away; the same cap moves to the tags TextMouth itself writes into the `.m4a`.
- **Treat a tag holding U+FFFD as missing:** unchanged; TextMouth reads the tags in either case.
- **Check copy protection first on the iPhone:** becomes necessary, because the iPhone would then convert WMA; `ASFHeader.isCopyProtected` runs before any decoder there too.
- **Name brew.sh in the install sentence:** goes away for the formats built in, and stays only if the installed path is kept for the rest.
- **Give a crashed ffprobe its own sentence:** goes away in-process; with a Mac helper it becomes "a crashed helper's own sentence".
- **Measure a CUE sheet's WMA or MKV file with ffprobe, not afinfo:** becomes easy, since the demuxer gives the length in-process.

## The ranked recommendation

Weighed against the 18,463,201-byte Release app, `make check`'s 20,000,000 bytes (1,536,799 to spare), and your aim of at most 25 MB:
1. **Set d, WMA and WebM, from a pinned release built by a script (way i): a helper on the Mac, in the app on the iPhone; the installed ffmpeg keeps the rest on the Mac.**
   The Mac app becomes 19,458,673 bytes and the iPhone app grows by 926,928; 4 CVEs since 2016 in its parts, one open (the Vorbis parser's CPU use, which the Mac's watchdog stops).
   It covers the one format with no other way in and the one you see most; a Matroska file of another codec goes to the installed ffmpeg on the Mac.
2. **Set b, WMA only,** the same way: 19,211,633 bytes; 3 CVEs, none open; if WebM on the iPhone is not wanted.
3. **Parity, set a or c,** only to drop Homebrew entirely: 20,147,041 to 20,871,537 bytes, so the gate rises to 21 MB; 16 to 22 CVEs, five open in 9.0.2.
4. **Nothing built in,** as today: no bytes and no upkeep; the iPhone keeps refusing these files, and the Mac needs Homebrew.

Ways ii and iii rank below way i for every set: more in the repository, slower updates, and the embedded paths to scrub.

## Questions for you

1. **Which formats should work without Homebrew, and on the iPhone?**
   Recommended: WMA and WebM (set d); Speex, Musepack, RealAudio, AVI, Flash video, and Matroska's other codecs stay with the installed ffmpeg on the Mac, and the iPhone refuses them as today.
2. **How should FFmpeg come in?**
   Recommended: a pinned release, checked by its signature and SHA-256 and built by a script into `build/` (way i): the repository gains a few kilobytes, a new release is minutes of work, and nothing of FFmpeg's code sits in git.
3. **On the Mac, a helper program or the app's own process?**
   Recommended: a helper, run as `TextMouthBraille` is, since the Mac app is not sandboxed; the iPhone runs the same libraries in its process, having no other way.
4. **The size gate.**
   Recommended: keep `make check`'s 20 MB; set d leaves the Mac app under it (19,458,673 bytes with the helper), and only parity would need it raised, to 21 MB.
5. **FFmpeg's updates.**
   Recommended: follow the 9.0 branch and rebuild at each of its point releases, with a TODO item for each, and check the CVEs naming the set's components at each version bump of TextMouth.
6. **The credit line.**
   Recommended: when FFmpeg is built in, the Mac app carries "This software uses libraries from the FFmpeg project under the LGPLv2.1" in a `Credits.rtf`, the iPhone app beside its licence notices, and both apps carry `Licenses/FFmpeg`.
7. **Matroska's AAC, FLAC, and AC-3 on the iPhone.**
   Recommended: later, and through Apple's own decoders, which already read those codecs, with FFmpeg only taking the packets out of the file; ask again if such files turn up.

## Not verified

- Most decoders of the parity set built and linked but decoded nothing, for want of samples (listed under "The decode check").
- Nothing ran on an iPhone or a simulator (this Mac has none); the iPhone builds were compiled, linked, and inspected only.
- The Mac helper, its own sandbox, and a crash inside it were not built or tried; whether `_exit` on a fatal signal keeps macOS's crash report away is untested here.
- The size inside the real app: the harness stands in for it, and TextMouth's Swift around the libraries would add a few kilobytes more (an estimate).
- The CVE reading rests on NVD's descriptions; a CVE whose description misnames its component would be misfiled.
- WMA's and RealAudio's patents: no patent search was made.
- The licence reading is a reading, not legal advice.

## Sources and files

- The release: `ffmpeg-9.0.2.tar.xz` from https://ffmpeg.org/releases/, 12,040,788 bytes, SHA-256 8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e, with its `.asc` signature; kept in `build/orchestrator/nov16/ffmpeglib/download/`.
- FFmpeg's pages: https://ffmpeg.org/download.html, https://ffmpeg.org/legal.html, https://ffmpeg.org/security.html; and in the release, `LICENSE.md` and `COPYING.LGPLv2.1` (SHA-256 246041b6…).
- Apple's pages:
  - the App Review Guidelines (https://developer.apple.com/app-store/review/guidelines/) and the Licensed Application End User License Agreement (https://www.apple.com/legal/internet-services/itunes/dev/stdeula/);
  - Third-party SDK requirements (https://developer.apple.com/support/third-party-SDK-requirements/);
  - "Describing use of required reason API" and `NSPrivacyAccessedAPIType` (developer.apple.com/documentation/bundleresources/), TN2435 "Embedding Frameworks In An App", and `NSApplication.AboutPanelOptionKey.credits`.
- The iOS 26.0 SDK's `usr/include/_stdlib.h` and `Foundation.framework/Headers/Foundation.h`.
- NVD's CVE API 2.0 (https://services.nvd.nist.gov/rest/json/cves/2.0?keywordSearch=FFmpeg), fetched at 09:23 today; OSS-Fuzz's `projects/ffmpeg/project.yaml` (github.com/google/oss-fuzz).
- TextMouth's own: `research/AUDIO-DECODERS-RESEARCH-2026-11-15.md`, `research/FORMATS-RESEARCH-2026-10-17.md`, `Scripts/agents/briefs/2026-10-17/formats/measurements.md`, `project.yml` (LAME, liblouis, `TextMouthBraille`), and `docs/developer/third-party-code.md`.
- The scripts: `research/ffmpeg-minimal/build.py` (builds and measures), `harness.c` (the open-and-decode path), and `cve_tally.py` (the CVE count).
