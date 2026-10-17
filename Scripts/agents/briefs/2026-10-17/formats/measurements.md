# Measured October 17, 2026: a bundled ffmpeg and liblouis (agent fmtmeasure, Sonnet)

The user asked: "How much would it be to add the encoding / decoding for all these formats? ... my current install of Text Mouth is 18.3 mb and I think I said I wanted to keep it below 30 mb if possible? Try measuring it using a test build." and, of braille: "It should support multiple braille tables ... Try researching braille blaster or similar tools to see how they get the tables." The build folders (670 MB) and the recipe script were left in the session's scratchpad under `fmtmeasure/`, which a later session will not have: rebuild from these lines.

## ffmpeg 9.0.2 (signature verified against ffmpeg.org's key), LGPL 2.1 or later only
- Configure: `--disable-everything --disable-autodetect --disable-network --disable-doc --disable-ffplay --disable-ffprobe --disable-avdevice --disable-swscale --disable-debug --enable-small`, `-mmacosx-version-min=14.0`, decoders `aac,mp3float,pcm_*,vorbis,opus,flac,wmav1,wmav2,wmapro,wmalossless,ape,wavpack,amrnb,amrwb,ac3,eac3`, encoders `aac,alac`, muxers `ipod,mp4`, demuxers `wav,mov,ogg,flac,matroska,asf,ape,wv,amr,ac3,eac3`, parsers `aac,mpegaudio,vorbis,opus,flac,amr,ac3`, protocol `file`, filter `aresample`. About 40 s a build at `-j2`.
- Stripped arm64 `ffmpeg` tool, every group: **2,400,768 B** (3,187,136 without `--enable-small`); with `--enable-lto` **2,086,640 B**; LTO and no unwind tables 1,971,616 B. Adding `--enable-audiotoolbox --enable-encoder=aac_at` (Apple's AAC encoder) costs 17 KB.
- Universal arm64 and x86_64: 5,153,280 B (4,576,896 with LTO). The installed app is arm64 only.
- What each group costs (bytes saved by leaving it out): WMA 83,808; Matroska and WebM 49,856; Ogg and FLAC with Vorbis, Opus, FLAC 150,048; AMR 67,088; AC-3 and E-AC-3 33,712; Monkey's Audio 16,624; WavPack 16,688; all of them 467,904. The fixed part (the tool, MP4, AAC, MP3) is 1,932,864 B.
- `-version`, `-L`, and the configure summary show no GPL, version 3, or nonfree component; the binary links only libSystem and the system's CoreFoundation, CoreVideo, and CoreMedia. Not run on any media file; TTA, Speex, Musepack, and DSD would need adding.

## liblouis 3.39.0 (SHA-256 matches GitHub's release digest), LGPL 2.1 or later
- `liblouis.20.dylib` arm64 stripped: **171,080 B** (static `liblouis.a` 194,256 B; universal 334,920 B).
- Tables: all 478 are 13.9 MB (3.6 MB zipped). **Core English** (UEB Grade 1 and 2, EBAE Grade 1 and 2, computer braille, the BRF, Unicode, and NABCC display tables): 24 files, **341,896 B**, all LGPL; loads from a folder of only those files, and UEB Grade 2 and EBAE Grade 2 round-tripped a sample sentence. The tables for VoiceOver's languages: 326 files, 7.67 MB, or 301 files, 3.46 MB (1.0 MB zipped) without Chinese, Korean, Japanese, and Hungarian. 74 tables carry no license text (54 ViewPlus `.tbl`, 20 hyphenation `.dic`), two IPA tables cite CC BY-SA 3.0, and `countries.cti` adds a GPL sentence: check before shipping any of those.

## Where braille tools get their tables
- BrailleBlaster (APH) ships all of liblouis 3.39.0's tables plus APH's Nemeth tables (488 files, 14.0 MB) inside its `jlouis` jar, with the native `liblouis.dylib`. NVDA copies liblouis's whole `tables` folder (a git submodule; 3.39.0 since 2026.3). Duxbury uses its own proprietary tables.
- macOS 26.3.1 keeps VoiceOver's tables in `/System/Library/ScreenReader/BrailleTables` (liblouis 3.34.0 with 485 tables, Duxbury, Rhine, and Apple's own for Japanese and Korean); nothing is downloaded. The public `AXBrailleTable` and `AXBrailleTranslator` (macOS 26.0 and later) returned no locales and no tables from a command-line tool and from an ad hoc signed app with VoiceOver running. Do not depend on them or on Apple's folder (unsupported, fixed at 3.34.0).

## The agent's recommendation
- FMT50: bundle an arm64 ffmpeg built with `--enable-small --enable-lto` and every group (about 2.1 MB; the app about 20.4 MB), with `aac_at` for Apple's AAC encoder; no universal binary.
- FMT31: route WMA, WavPack, Monkey's Audio, Matroska and WebM, AMR-WB, and Ogg through it in the watched child process, with a forced demuxer, `-protocol_whitelist file`, and `-map 0:a:N` (audio only).
- FMT21: vendor liblouis 3.39.0 statically (0.17 MB) with the 24-file core English tables (0.34 MB), about 0.55 MB; build the table picker from the tables' `#+language` and `#+type` headers (`lou_findTables`); offer other languages as a 3.5 MB pack or a download (all tables would bring the app to about 34 MB).
- FMT20: with liblouis in, a separate Grade 1 decoder is not needed (`lou_backTranslateString` covers UEB and EBAE); keep the BRF page and heading model, and measure back-translation on real books first.
