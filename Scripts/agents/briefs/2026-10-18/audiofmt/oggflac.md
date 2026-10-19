# Task oggflac: Ogg FLAC accepted, and converted to Apple Lossless (FMT14, step 1)

Slug `audiofmt-oggflac`, branch `audiofmt/oggflac` made from `team/audiofmt`. Read `Scripts/agents/briefs/2026-10-18/audiofmt/common.md` first.

TextMouth refuses an Ogg FLAC file (.oga or .ogg) today: `OggHeaderReader` knows Vorbis and Opus only, so the import says the file "could not be read for converting". `afconvert` turns Ogg FLAC into Apple Lossless (verified), and task `formats` (on `team/audiofmt` already) made the converter write Apple Lossless for any source whose `SourceInfo.isLossless` is true. This task teaches the header reader FLAC and passes it to the converter. The October 14 rule holds: the Ogg FLAC file is read by hand and by afconvert in a child process, never by Apple's frameworks in the app.

## 1. `TextMouth/Services/OggHeaderReader.swift`
- **The codec.** `Codec` gains `case flac` (line 16). `Header` gains `let bitsPerSample: Int?`: FLAC's, nil for Vorbis and Opus. Update the type's doc comment (lines 3-13).
- **`identify(_:)`** (about lines 536-553) accepts FLAC's first packet. The packet holds:
  - `0x7F` and "FLAC";
  - major version 1 and minor version 0, one byte each;
  - a 16-bit big-endian count of header packets (0 means unknown);
  - "fLaC";
  - a 4-byte metadata block header, which must be type 0, STREAMINFO, of length 34;
  - the 34-byte STREAMINFO.

  From STREAMINFO, starting at the packet's byte 17: the sample rate (20 bits from byte 27), the channels (3 bits, plus 1), the bits per sample (5 bits, plus 1), and the total samples (36 bits). Refuse a major version other than 1, a missing "fLaC", a block that is not STREAMINFO, and a sample rate or channel count of 0. The existing `testOtherCodecsInOggAreRefused` (`OggHeaderReaderTests.swift:346-353`) gives a FLAC packet of zeros and must still pass unchanged. See https://xiph.org/flac/ogg_mapping.html and https://xiph.org/flac/format.html#metadata_block_streaminfo.
- **The header packets** that follow are FLAC metadata blocks, each led by a one-byte type (the high bit marks the last) and a 24-bit big-endian length. A VORBIS_COMMENT block (type 4) carries the tags as a Vorbis comment without the `0x03 "vorbis"` signature or framing bit. Teach `parseTags` that form. The header count is the packet's own field, or, when it is 0, the packets read until one marked last.
- **The length.** The last granule position divided by the sample rate, as for Vorbis. Where STREAMINFO's total samples is above 0, it must agree with the granule to within one second; otherwise the file is refused (nil), as contradicting itself.
- Every read stays bounds-checked, as the file's own doc comment requires.

## 2. `TextMouth/Services/ImportAudioConverter.swift`
In `inspect(_:)`, an Ogg header of codec `.flac` gives a `SourceInfo` with `formatID` "flac", the header's `bitsPerSample`, and `isLossless` true. So `plan(for:info:)` gives `.convertToAppleLossless`, and `target(for:bytes:)` a 16-bit ALAC for a 16-bit source. Change nothing else there.

## 3. Tests
- **`OggHeaderReaderTests`** (append a section; change no existing test):
  - a FLAC stream built by the file's own `Builder`: the identification packet, a VORBIS_COMMENT packet with TITLE and ARTIST, an audio page, and an end page, giving codec, channels, rate, bits, duration, and tags;
  - a wrong major version, a missing "fLaC", a STREAMINFO with rate 0, and total samples that contradict the granule, each refused;
  - a header count of 0 with the comment block marked last.
- **A real Ogg FLAC file,** in a new class `OggFlacConversionTests` (new file):
  - Make it in the test's temporary folder by running `/usr/bin/afconvert -f Oggf -d flac <copy of TestData/format-samples/flac-chapters/three-tones.flac> <dir>/three-tones.oga` with `Process`. That is a child process, never in the app's own frameworks; check its exit status.
  - `OggHeaderReader.read` gives flac, 1 channel, 22,050 Hz, 16 bits, and about 4.0 seconds.
  - `ImportAudioConverter.convert` gives an .m4a that `AudioFileInfo.read` reports as "alac" with 16-bit source data, lasting within the tolerance, and that `AudioMediaProbe` passes.
  - A single-file import of the .oga (as `OggImportConversionTests` imports) gives a book whose file is `three-tones.m4a` and plays as Apple Lossless.
  - An Ogg Vorbis tone (`TestData/audio/ogg-vorbis-tone.ogg`) still converts to AAC.
- `/opt/homebrew/bin/xcodegen generate`, and commit the project with the tests.

## Commits
1. FLAC in `OggHeaderReader`, with its tests.
2. The converter's mapping, with `OggFlacConversionTests`.

## Test classes (one run)
`OggHeaderReaderTests OggFlacConversionTests OggAudioConverterTests OggAfconvertTests OggImportConversionTests ImportAudioFormatsTests AudioMediaImportTests`

## Do not touch
Every file but the two named and the tests; no `*.md`.
