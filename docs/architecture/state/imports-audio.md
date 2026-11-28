# Imports: audio
<!-- id: imports-audio; keys: audio import, Ogg, afconvert, afinfo, M3U playlist, Nero chapters, audiobook, conversion; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## A manifest's title and author
<!-- id: manifest-title-author; keys: manifest.json, book title, book author, blank title, ZIP name, audiobook folder; src: TextMouth/Parsers/AudioBookParser.swift, TextMouth/Parsers/AudioManifest.swift, TextMouth/Services/FileImportService.swift -->

A manifest's title and author (FR17): publishTracks and AudioBookParser take them through AudioManifest.bookTitle and bookAuthor, which read one that is empty or only whitespace as none, so the name of the ZIP or folder, or Unknown, stands as for a missing one.
The manifest's stored title and author keep every byte.

## Audio the import converts
<!-- id: audio-import-converts; keys: convert audio, Ogg, MP2, AC-3, afinfo codec, sniffer, ZIP of tracks, feed episode; src: TextMouth/Services/FileImportService+AudioConversion.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/BookManifestEditing.swift, TextMouth/Services/ImportFailure.swift, TextMouth/Services/AudioFileInfo.swift, TextMouth/Parsers/AudioContentSniffer.swift -->

Audio the import converts (B06, FMT09): FileImportService.publishReadableBook converts a staged book's audio first (convertImportedAudio(of:in:keepingOriginals:run:), in FileImportService+AudioConversion.swift; step .convertingImportedAudio(done:of:)), before anything reads it as a book.
So a ZIP of tracks, a folder, a single file, a playlist, and a feed's episode are converted in one place, each converted file renamed in the manifest through BookManifestFile.change.
ImportAudioConverter.tracksNeedingConversion(in:) (a folder) and needsConversion(among:) (files) choose the tracks, by what each holds.
Their verdict(for:) takes the extension (convertedExtensions: oggExtensions and coreAudioExtensions) and then AudioContentSniffer.kind(of:), which reads a file's first 64 KB by hand with no Apple audio API.
Ogg, AC-3 and E-AC-3, CAF, AIFC, AU, Wave64, AMR, 3GPP audio, and MPEG layers I and II convert.
WAVE (RIFF, RF64, BW64), AIFF, FLAC, MP3, and ADTS AAC are left.
MPEG-4, QuickTime, and anything unrecognized go to afinfo, whose codec decides (playsAsIs(formatID:fileType:): AAC, Apple Lossless, and MP3 in them stay).
So an Ogg file named .m4a, or an MP2 feed episode named .mp3, is converted.

## Reading a source's audio facts
<!-- id: reading-source-audio-facts; keys: afinfo, afconvert, AAC, Apple Lossless, bit rate, bit depth, SourceInfo, failed Ogg book; src: TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/OggHeaderReader.swift, TextMouth/Services/AudioFileInfo.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Parsers/AudioMediaProbe.swift, TextMouth/Parsers/AudioContentSniffer.swift, TextMouth/Services/AudioEditing/AudioEditComposition.swift, TextMouth/Services/TranscriptionEngine.swift, TextMouth/Services/TranscriptionService.swift, TextMouth/Services/AudioPlaybackService.swift, TextMouth/ViewModels/OggConversionProgress.swift, TextMouth/ViewModels/LibraryViewModel+OggConversion.swift -->

ImportAudioConverter reads a source's facts from OggHeaderReader for Ogg (Vorbis, Opus, or FLAC), and from AudioFileInfo for the rest: afinfo -x -r, run by WatchedProcess.runCapturingOutput, gives the container, codec, channels, sample rate, bit depth, length, and whether it names a channel layout.
No Apple audio API opens the source in TextMouth's process.
AudioFileInfo.parse(xml:) first replaces every byte sequence that is not UTF-8 with U+FFFD.
afinfo prints a path with a letter outside ASCII as bytes that are not UTF-8 in the alert of a property it could not read, and XMLParser would refuse the whole answer for a book in a folder named "Café".
The plan, plan(for:info:), is leaveAsItIs, convertToAAC, or convertToAppleLossless when the codec keeps every bit (SourceInfo.isLossless: lpcm, alac, flac).
The target, target(for:bytes:), gives AAC the source's average bit rate (bytes × 8 ÷ duration) rounded up to the next standard rate (bitRate(averaging:channels:accepted:), 64 to 192 kbit/s for stereo, half for mono) at its own sample rate where AAC takes it (sampleRate(for:)).
It gives Apple Lossless the smallest of 16, 24, or 32 bits that holds the source's samples (appleLosslessBitDepth(forBitsPerSample:): 24 for 17 to 20 bits too, and when the depth is unknown or the samples are floating-point).
A 20-bit Apple Lossless file is no longer played as it is: playsAsIs(formatID:fileType:bitsPerSample:) converts it, since AVAssetReader cannot read one.
Arguments from afconvertArguments(from:to:info:target:) never pass -c, since afconvert refuses it for AAC above stereo.
AudioMediaProbe, AudioEditBase.load, and the transcriber refuse every format the import converts by ImportAudioConverter.isNeverDecodedInApp(_:), a converted extension other than TextMouth's own CAF or a file that begins with OggS (AudioContentSniffer.isOgg(at:)).
AudioPlaybackService.metadataAsset(for:) asks isConvertedAtImport, by extension alone, since an import reads a source before it converts it.
OggConversionProgress.markFailed keeps a failed book from being tried again before the next launch (B09).

## Probing an audio file's duration
<!-- id: probing-audio-file-duration; keys: audio duration, unplayable audio, AVAssetReader, decode check, header length, hung read, Swift concurrency pool; src: TextMouth/Parsers/AudioMediaProbe.swift, TextMouth/Parsers/AudioBookParser.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Models/AudioSampleForm.swift -->

AudioMediaProbe.duration(of:) (Parsers/AudioMediaProbe.swift) tells how long an audio file plays or why it cannot be played, and decodes the opening and the last second of its track to confirm its header.
AudioBookParser and BookContentAnalysisService reach it through AudioMediaProber, and ImportAudioConverter directly.
Since 0.4.5 that decoding check runs on a concurrent dispatch queue of its own, never in Swift's concurrency pool, where a read that never returned (AVAssetReaderOutput.copyNextSampleBuffer() on a GitHub runner) held one of its few threads for good.
The probe waits for it 60 seconds at most (decodeDeadline): then the check's readers are told to stop (AVAssetReader.cancelReading()) and the file passes on its header's length.
The deadline holds the check's job weakly, so a check that answers frees the file's asset and readers at once.
A decode that fails at the opening is told as damage, unless the track's own description names a form of samples the decoders do not read (AudioSampleForm.isDecodable, B15): then the problem is .unsupportedSamples.
The form is looked at only after the decode has failed, and only for linear PCM, so a Mac that decodes a form never refuses it, and a description that is not believed (a depth past 64 bits, or a frame too small for its channels) leaves the file to the damage checks.
The table was decided by test on macOS 26: integers of 8, 12, 16, 20, 24, and 32 bits and floats of 32 and 64 bits read; integers of 33, 40, 48, and 64 bits and floats of 16 and 24 bits are refused.
AudioMediaProblem.sentence(file:container:original:) says it with AudioSampleFormWording.refusal, where the other problems complete the damage sentence.
The sentence is "“Talk.wav” uses 64-bit integer samples, which TextMouth can't play.
  Convert it to 16-bit or 24-bit integer samples, then import it again.", and a float says "16-bit floating-point".
FileImportService.describedAudioFailure passes the refusal through for a single file (AudioParseError.refusesAValidFile), and AudioBookParser says it for a track.

## Audio of more than two channels
<!-- id: audio-more-than-two-channels; keys: surround, 5.1, downmix, stereo, channel layout, centre channel, afconvert --mix, disk space; src: TextMouth/Services/ImportAudioConverter.swift -->

Audio of more than two channels (maximumChannels is 2) takes two steps (write(_:to:info:target:using:)):
- downmixArguments writes a hidden stereo CAF ("`.<UUID>.audio-downmix.caf`", linear PCM, 16 bits for AAC and the lossless depth (24 for 17 to 20 bits), with -c 2 --mix, because without --mix afconvert drops channels by position and a PCM source's centre came out silent), and
- afconvertArguments encodes that file, which is removed as soon as the second step ends.

Before the first step the volume's free space must hold the PCM file and a 512 MB reserve (downmixBytesNeeded(duration:target:), Failure.notEnoughSpace), and a source of more than two channels that names no layout is refused (Failure.unlabelledChannels).
Apple's normalized mix puts the centre in both channels about 10.7 dB down for PCM and 13.7 dB down for AC-3, measured on macOS 26.3.1.

## What watches a conversion
<!-- id: what-watches-conversion; keys: watchdog, time limit, output cap, stall, afconvert limits, afinfo limits, lying header, converted file check; src: TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/AudioFileInfo.swift, TextMouth/Parsers/AudioMediaProbe.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Models/AudioSampleForm.swift -->

What watches a conversion: afconvert gets

- 60 seconds plus a tenth of the track's length,
- 1 GiB,
- a stall allowance of 20 seconds,
- the default processor-time allowance, and
- an output cap of four times what it should write and 16 MB more (outputCap(of:duration:target:)), set as Limits.maximumOutputBytes.

The expected output is the AAC rate times the length, 320 kbit/s where the encoder chooses, or for Apple Lossless and the downmix's PCM the length times rate, channels, and bytes a sample.
AudioFileInfo.read(_:using:) gets 30 seconds plus one for each 20 MB, 512 MiB, and a cap of 1 MiB on what afinfo prints.
It believes a length only up to a year and only as far as the file's bits at the codec's lowest bit rate allow (isPlausible(inFileOfBytes:), logged as AUDIO_INFO_IMPLAUSIBLE), so a lying header cannot lift the time limit or the cap.
A file it cannot read is Failure.unreadable.
AudioFileInfo.sampleForm names the form of linear PCM from afinfo's bit_depth and data_type (only "integer" or "float"), with max_packet_size and interleaved to check the frame holds the channels.
When afconvert itself ends with a status above zero on a source whose form no decoder reads, ImportAudioConverter.convert throws Failure.unsupportedSamples (the same sentence) in place of "the converter ended with code N"; a kill or a failure to start keeps its own failure.
AUDIO_CONVERSION_KILLED (in place of OGG_CONVERSION_KILLED) and AUDIO_INFO_KILLED are storage events.
The converted file is written under "`.<UUID>.audio-conversion.m4a`", checked by AudioMediaProbe (it plays, and lasts as long as its source to within allowedLengthError(for:), a second and half a percent), and only then named.

## Kept originals
<!-- id: kept-originals; keys: Keep Original, keep original audio, setting, hidden folder, Export original file, converted audio, feed episode; src: TextMouth/Services/ConfigService.swift, TextMouth/Services/FileImportService+AudioConversion.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/Services/BookExportService.swift, TextMouth/Models/ConvertedOriginalWording.swift -->

Kept originals: with the setting on (ConfigService's keepsOriginalOfConvertedAudio, read by keepsOriginalsOfConvertedAudio(feedLink:), and never for a feed's episode), convertImportedAudio moves each source into the package's hidden .convertedOriginals folder.
That is in place of removing it (removeSources(of:)).
ImportAudioConverter.keepSources(of:from:inPackage:) keeps each source under its path from the book's folder of tracks, or by its own name for a single file.
The folder is hidden so that every track scan passes it by and FileImportService.isPackageContentName refuses it; a kept Ogg file is never opened, and BookExportService.convertedOriginalItem copies the files out as Export's Original file.
ConvertedOriginalWording holds the setting's words.

## Package track scans
<!-- id: package-track-scans; keys: TrackScan, track scan, packageTrackExtensions, stray audio file, chapter count, Ogg books, AIFC, own CAF; src: TextMouth/Parsers/AudioBookParser.swift, TextMouth/Models/Book.swift, TextMouth/Services/ImportAudioConverter.swift -->

Package track scans: AudioBookParser.audioFiles(in:scan:) takes a TrackScan.
The import's scans (.importing) take every audio format (BookFormat.audio.fileExtensions, which ends with coreAudioExtensions), since they run before the conversion.
A package's scans (.package: loading the reader, re-analysis, a manifest edit, the library's checks) take BookFormat.packageTrackExtensions, which leaves out the formats the import converts (coreAudioExtensions).
So a stray .aifc, .au, or .ac3 left in a package is neither played nor counted as a chapter.
Ogg stays, since the library converts the Ogg books it holds and that conversion needs their tracks found.
TextMouth's own CAF is taken by its name and place (isOwnCAF(atPath:)).

## Chapters in audio files
<!-- id: chapters-audio-files; keys: Nero chapters, chpl, M4B, audiobook chapters, moov udta, MP4 box, chapter list; src: TextMouth/Services/AudioPlaybackService.swift, TextMouth/Parsers/NeroChapterReader.swift -->

Chapters: AudioPlaybackService.extractChapters(from:) reads a Nero chapter list by hand when AVFoundation finds no chapter in an M4A, M4B, MP4, M4V, or MOV file (NeroChapterReader.mayHoldChapterList(_:)).
NeroChapterReader.read(at:) walks the box headers of the file to the chpl atom under moov and udta on a FileHandle, never reading the media, with every size checked and every level capped.
NeroChapterReader.bookChapters(from:fileDuration:) sorts the chapters, drops one at or past the end of the file, and names an untitled one "Chapter N".

## Chapters in WAVE, AIFF, FLAC, and Ogg files, and in converted ones
<!-- id: chapters-markers-cue-ogg; keys: FileChapterReaders, AudioMarkerList, FLACCueSheetReader, CHAPTER comments, ChapterTrackWriter, keepChapters, AUDIO_CHAPTERS_NOT_KEPT, leadingTitle; src: TextMouth/Parsers/FileChapterReaders.swift, TextMouth/Services/AudioMarkerList.swift, TextMouth/Parsers/FLACCueSheetReader.swift, TextMouth/Services/ChapterTrackWriter.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/OggHeaderReader.swift, TextMouth/Services/AudioFileInfo.swift -->

Chapters: FileChapterReaders.bookChapters(of:lasting:leadingTitle:) is the one place that picks the reader by a file's kind, when AVFoundation finds no chapter (AudioPlaybackService.extractChapters):
- a Nero list for an MPEG-4 file (above);
- the CUESHEET block of a FLAC file, or a cue sheet kept in its CUESHEET comment, by FLACCueSheetReader, which walks the metadata blocks by their headers on a FileHandle and is asked only when the file has no CHAPTER comments, which AVFoundation reads and which always win;
- the cue points and labels of a WAVE or Broadcast Wave file, and the MARK chunk of an AIFF file, by AudioMarkerList (Core Audio's marker list, kAudioFilePropertyMarkerList), opened only for a file a reader may open (ImportAudioConverter.isNeverDecodedInApp), and reading chunks, not samples.
FileChapterReaders.placedChapters(_:lasting:leadingTitle:) makes the places a book's chapters: sorted, each lasting until the next, an untitled one "Chapter N", and the sound before the first place a chapter titled by the book when that place is not at the start.
A list that makes one chapter makes none, so a book of one heading keeps its title.
A WAVE or AIFF file whose only marker is at 0 s so has no chapters.

A file the import converts keeps its chapters through the conversion:
- SourceInfo.chapters holds them:
  - an Ogg file's CHAPTERnnn and CHAPTERnnnNAME comments (xiph.org's chapter extension), read by OggHeaderReader.chapters(in:) from the file's own bytes, never through Apple's frameworks;
  - a CAF file's markers, read from afinfo's output in its child process (AudioFileInfo.markers);
  - an MPEG-4 file's own.
- ImportAudioConverter.keepChapters writes them into the checked .m4a as a chapter track (ChapterTrackWriter, copying the samples as they are, not re-encoding) into a hidden file beside it, checks that file as the conversion was checked, and only then replaces the .m4a.
  A failure of either keeps the .m4a without chapters and logs AUDIO_CHAPTERS_NOT_KEPT with the file's name and an error's domain and code; Stop ends the import, the file as it was.
- A conversion the library runs on an older book's Ogg files keeps none, so that book's chapters stay as they were.
- A file the helper converts keeps its own chapters: FFmpegAudioConverter.convert writes the report's chapter marks with ImportAudioConverter.keepChapters itself (when keepingChapters), so ImportAudioConverter.convert returns before its own call for it.

## Cue sheets and Audacity label files
<!-- id: cue-sheets-label-files-import; keys: CueSheet, CueSheetArrangement, arrangeByCueSheets, importCueSheetWithReport, AudacityLabels, FMT24, FMT06, measuredLengths; src: TextMouth/Parsers/CueSheet.swift, TextMouth/Parsers/CueSheetArrangement.swift, TextMouth/Parsers/AudacityLabels.swift, TextMouth/Services/FileImportService+CueSheets.swift, TextMouth/Models/CueSheetWording.swift -->

- CueSheet.parse reads FILE, TRACK, TITLE, PERFORMER, and INDEX 01 (frames of 1/75 s); INDEX 00 is ignored, since the gap belongs to the track before.
  CueSheet.read(at:) decodes the file as a small text file is (a byte-order mark, UTF-16, Windows-1252, or Latin-1) up to maximumByteCount, 1 MiB, with at most 10,000 tracks and 10,000 files.
- CueSheetArrangement turns sheets and label files into sections written as a manifest's segments, so the book plays as a DAISY book's sections do:
  - Files are found as a playlist's are (M3UPlaylist.resolve(inFolder:)): only files inside the sheet's folder, each skipped name told with its reason.
    A missing, outside, or non-audio name falls back to an audio file of the same stem beside the sheet, and a sheet of one file to one of the sheet's own stem.
  - A track runs to the next track's start, across a file's end into the next file; the first takes in everything before it, and the last runs to the end of the last file.
  - Every file a sheet or label file names is measured first (measuredLengths(of:): a file played as it is by AVFoundation's prober, an Ogg file from its own pages, any other by afinfo in its child process), and a sheet that runs past its audio is left unused with a notice.
  - A track no sheet plays stays a section of its own, and the sections keep Finder's order, each sheet's at its first file's place.
  - A label file (AudacityLabels, a .txt of tab-separated start, end, and text, and nothing else) is a sheet of one audio file, the file of its stem or the only one beside it; a label with no text is titled "Label N".
  - FFmpeg-only formats, which afinfo cannot read, are measured by the helper's probe (FFmpegAudioConverter.length(of:using:)), so a sheet over a WMA or Matroska file is checked like any other.
- Folder and ZIP imports call arrangeByCueSheets(in:) when AudioManifestLocation.find finds no manifest, and write the sections as a manifest where a new one goes; a manifest.json always wins, and a folder without a sheet is left as it was.
  FileImportService.publishingWithoutSheetsOnMisfit publishes with the sections.
  If the book's parse finds one past its file's end after the conversion (AudioParseError.placesASectionOutsideItsFile), it publishes once more without them, their manifest removed, with CueSheetArrangement.noticeWithoutItsSections.
  A ZIP holding a .txt is a batch of books (isAudioZip), so a label file arranges a folder's tracks alone.
- A cue sheet chosen alone is importCueSheetWithReport, as a playlist is: the files it names inside its folder become one book, named by its title, with its performer as author, hashed by its files' paths and bytes and its own, and none deleted afterwards.
  Its refusals are CueSheetError (tooLarge, noTracks, noAudio, timesPastAudio) in CueSheetWording's sentences.
- FLAC files' cue sheets are read by FLACCueSheetReader (above).

## TextMouth's own TTA, WavPack, and Monkey's Audio readers
<!-- id: own-audio-readers; keys: OwnAudioFormat, OwnAudioConverter, TTADecoder, WavPackDecoder, MonkeysAudioDecoder, OwnAudioError, .wvc, APEv2; src: TextMouth/Parsers/OwnAudio/OwnAudioFormat.swift, TextMouth/Parsers/OwnAudio/OwnAudioSource.swift, TextMouth/Parsers/OwnAudio/OwnAudioTags.swift, TextMouth/Services/OwnAudioConverter.swift, TextMouth/Parsers/OwnAudio/WavPackUnpack.swift, TextMouth/Parsers/OwnAudio/MonkeysAudioDecoder.swift, TextMouth/Parsers/OwnAudio/TTADecoder.swift, TextMouth/Platform/iOS/Services/OwnAudioMemoryWatch+iOS.swift; status: incomplete; issues: B21 -->

- Owner: OwnAudioFormat (trueAudio, wavPack, monkeysAudio) tells a file by its signature, after any ID3v2 tag (OwnAudioFormat.of), and gives each reader a decoder (format.decoder(of:companion:)).
  The readers are Swift ports of BSD-licensed decoders (the TTA hardware players library 1.2, WavPack 5.9.0, and Monkey's Audio SDK 13.47), compiled into both apps from TextMouth/Parsers/OwnAudio.
  Their notices ship in Licenses/TrueAudio (README and COPYRIGHT), Licenses/WavPack, and Licenses/MonkeysAudio.
- The import: these files always convert (their extensions are in ImportAudioConverter.ownReaderExtensions and convertedExtensions), and one under another name is caught by its bytes; FFmpegAudioConverter.converts(_:) says no for them.
  OwnAudioConverter.sourceInfo(of:) reads the header, refuses a length past a year as damaged, and returns the chapters of an APEv2 Cuesheet item (chapters(in:lasting:), by CueSheet and CueSheetArrangement.heading).
  OwnAudioConverter.write decodes block by block (framesPerAppend) into an AVAssetWriter that sees only PCM made here.
  A lossless source is written as Apple Lossless at its depth, a source of 17 to 20 bits at 24 (appleLosslessBitDepth, since the writer's 20-bit files fail the media check), a float at 24, and a hybrid WavPack file without its .wvc as AAC.
  More than two channels are mixed to stereo (OwnAudioSamples.stereo).
- The .wvc: OwnAudioConverter.companion(of:) finds it by name beside the .wv; the import copies it with its file, ImportAudioConverter.removeSources removes it with its source, and the kept originals move it beside its file.
  A damaged .wvc ends in OwnAudioError.companionDamaged, whose sentence names it.
- Untrusted input: OwnAudioBytes reads with pread(2) and never maps a file, every read is bounds-checked, arithmetic wraps or converts with checks, and each loop is limited by what the file holds, so a crafted file ends in an OwnAudioError, never a trap.
  Allocations are capped before they are made: a Monkey's Audio frame by the SDK's own limits (MonkeysAudioDecoder.mostFramesPerFrame: a million frames of audio, ten million at Insane) and maximumSamplesPerFrame.
  Stop is seen between blocks and in the writer's wait, and the decode runs off the main actor.
- Header shifts: WavPack files of 12 or 20 valid bits, or of 24 in 32, are shifted back to their own width after the unpack, so the samples handed to the encoder are exact (review10 finding 1).
- Not read: Monkey's Audio before 3.99 and WavPack before 4 (refused with their sentences), True Audio with a password or of floats, DSD, and a later WavPack block that changes the first block's sample format (crafted files only).
- The iPhone runs the same readers and conversion, with no helper program (see [What the iPhone's import refuses](../platforms-phone-interface.md#what-the-iphones-import-refuses)).
  A crafted header may ask for a frame of 24 million samples, about 200 MB, and four conversions of one ZIP run at once, so before each block `OwnAudioMemoryWatch` asks `SessionMemoryFloor`, as FFmpeg's in-app run does.
  A conversion that crosses the floor ends with FFmpeg's memory sentence in `ImportAudioConverter.Failure.killed`: "Converting a.ape was stopped because the app's memory grew by more than 700 MB while it ran."
  The Mac has no such watch.
  Open Book and "Open in" copy each file alone (`PhoneImportCopy`), so a hybrid WavPack book loses its .wvc and becomes AAC; Import Folder and a ZIP keep it (B21).

## Audio only ffmpeg reads
<!-- id: audio-only-ffmpeg-pointer; keys: WMA, Matroska, WebM, FFmpeg; src: TextMouth/Services/FFmpegAudioConverter.swift -->

The formats macOS cannot read (WMA, Matroska, WebM, and the rest) are converted by the FFmpeg built into the app: see [Imports: audio only FFmpeg reads](imports-audio-ffmpeg.md).

## Playlists
<!-- id: playlists; keys: playlist import, .m3u, m3u8, folder book, duplicate playlist, skipped entries, Book Imported alert, streaming playlist; src: TextMouth/Parsers/M3UPlaylist.swift, TextMouth/Parsers/PLSAndXSPFPlaylist.swift, TextMouth/Models/PlaylistImportWording.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/BookManifestEditing.swift, TextMouth/Parsers/AudioManifest.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Models/ImportProgressWording.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift -->

Playlists (FMT10): importFileWithReport sends an M3U or M3U8 file (M3UPlaylist.isPlaylist, by extension) to importPlaylistWithReport, which builds a folder book through publishTracks as importAudioFolderWithReport does.
M3UPlaylist.read(at:) takes at most 4 MiB (an .m3u8 as UTF-8, an .m3u through TextFileDecoder) and parse reads #PLAYLIST, #EXTINF, and #EXT-X- lines.
A stream is PlaylistImportError.streaming, and a list of only web addresses PlaylistImportError.onlyWebAddresses.
Its resolve(inFolder:) uses only a file that realpath(3) puts strictly inside the playlist's own folder, and skips these, each as a Skipped with a SkipReason whose words the notice quotes:

- a web address,
- a Windows drive,
- a path outside,
- a missing entry,
- a folder,
- a file that is not one of BookFormat.audio's extensions,
- anything hidden or not a regular file, and
- a repeat (distinctTracks(of:) counts a second spelling of one file as a repeat).

PLS and XSPF files (FMT12, PLSAndXSPFPlaylist.swift) are read into the same M3UPlaylist, so the rest is one path with the same folder rule and web-address refusal.
PLS is read by file number (FileN, TitleN), a repeated number keeping the first, and names no playlist, so the book takes its file's name.
XSPF takes each track's first location, resolved against xml:base, and the playlist's title names the book; its creator is ignored.
A .pls that is a W3C pronunciation lexicon is refused with PlaylistImportWording.pronunciationLexicon(fileName:): "“FILE” is a pronunciation lexicon, not a playlist.", and on the Mac "To use it, choose Import Rules… on the Text tab in Settings."
With no track left it throws PlaylistImportError.noTrack.
Each track is copied to the same path in the staged audio folder, with an AudioManifest built in memory from the playlist's order and titles and written there (BookManifestFile.encoded), so the manifest check and the conversion treat the book as any folder of tracks.
The book is known by folderHash over the tracks' paths and the playlist's own file name, each with the MD5 of its bytes, so the same playlist imported twice is a duplicate.
ImportedBook.isFromFolder is set, so mayDeleteOriginal is false.
ImportedBook.notice holds PlaylistImportWording.notice(playlistName:skipped:) (at most 10 entries named within 600 characters, each location at most 60 characters, a file name of more than 40 shortened in its middle), which ImportedBook.announcement(warning:) joins to the warning.
The library presents it under ImportProgressWording.bookImportedTitle ("Book Imported", where a failure's alert says "Error") and does not open the book.

## OggHeaderReader
<!-- id: oggheaderreader; keys: Ogg header, granulepos, chained Ogg, multiplexed stream, Ogg tags, Ogg duration, page CRC, cover art; src: TextMouth/Services/OggHeaderReader.swift, TextMouth/Services/AudioPlaybackService.swift -->

OggHeaderReader (Services/OggHeaderReader.swift, REV17a) reads an Ogg file's codec (Vorbis, Opus, or, since FMT09, FLAC), channels, sample rate, bit depth (FLAC), length, and tags from the file's own bytes.
Ogg FLAC's first packet (identifyFLAC) is the mapping header, "fLaC", and the STREAMINFO block, which gives the rate, channels, bits a sample, and total samples.
The length is the last granule position, refused when STREAMINFO's total differs from it by more than a second.
Its tags are the VORBIS_COMMENT block among the header packets (flacTags).
Its read(at:) takes the first 256 KB (headLength) and the last 70,000 bytes (tailLength) and hands them to parse(head:tail:), which is pure and bounded whatever the bytes are.
A page counts only when it lies wholly inside the bytes and its CRC-32 checks (crc(of:)), so a stray "OggS" in audio data costs nothing, and at most 256 rejected candidates are tried in the tail.
It takes:

- the identification packet of the Vorbis, Opus, or FLAC stream among the leading start-of-stream pages (audioStream(in:)),
- the length from the last page of that same stream in the tail, less the granule position the stream starts at (StreamStart.startOffset), and
- the tags from its comment packet.

audioStream(in:) walks the leading start-of-stream pages: a multiplexed file begins with one such page for each stream, and an Ogg Skeleton stream's fishead may come first.
So the walk goes on while pages have the start flag, and a page that fails its checks ends it.
The first serial whose first packet identify accepts is the stream.
Speex, Theora, or an unknown codec gives nil.
A page of another stream, as in a multiplexed file, is passed over in the tail, so a chained file whose tail holds only another stream's pages gives nil.
StreamStart.startOffset is 0 for a stream that begins at the start of its recording, more for one cut from a longer stream, as a live broadcast joined an hour in.
The tags are title; artist, else performer; album; genre; date.
A comment packet over 256 KB, cover art say, gives empty tags.
A length over a year (maximumDuration) gives nil, so no later Int(seconds) can overflow, and Opus always reports 48,000 Hz.
The start offset is found as libvorbisfile and opusfile find a stream's first sample (startOffset(of:codec:)).
Its lead(of:headerCount:in:) gathers the stream's packets from its first page through its first audio page, passing over up to maxAudioPagesWithoutGranule (16) pages that complete one without a granule and stopping, keeping what it has, at the first page that fails its checks.
The first audio page is the first page after the header packets (3 for Vorbis, 2 for Opus) that completes an audio packet and has a granule position of 0 or more.
The offset is that page's granule less the samples its packets produce, never below 0.
Opus counts each packet's frames from its TOC byte (RFC 6716), a packet over maxOpusPacketSamples (5,760) being invalid.
Vorbis counts a quarter of each packet's block size plus a quarter of the previous packet's, the first packet giving none, from the identification packet's block sizes and the setup packet's modes.
It is 0 when anything cannot be read, and an offset past the last granule is ignored. streamStartOffset(inHead:) gives tests the offset.
The metadata readers use it too, through AudioPlaybackService.metadataAsset(for:) ([media playback](media-playback.md)).

## WatchedProcess
<!-- id: watchedprocess; keys: child process, watchdog, ulimit, process timeout, reaper, kill children, afconvert, textutil; src: TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Platform/iOS/Services/WatchedProcess+iOS.swift, TextMouth/Models/CountWording.swift, TextMouth/Services/PlaybackMemoryGuard.swift, TextMouth/Platform/macOS/App/AppDelegate.swift -->

WatchedProcess starts a tool as /bin/sh, which sets the kernel's processor-time limit (ulimit -t, from Limits.effectiveMaximumCPUSeconds: maximumCPUSeconds, else four times maximumSeconds) and then replaces itself with the tool (exec).
So the pid it watches, measures, and kills is the tool's own.
A child the kernel ends at that limit (SIGXCPU) is reported as KillReason.usedTooMuchProcessorTime.
The same shell also sets the kernel's file-size limit (ulimit -f, whole kilobytes: fileSizeLimitForShell(_:)) from Limits.maximumOutputBytes, and the watchdog kills a child whose watched file passes that cap (KillReason.wroteTooMuch, "its output passed N MB").
A child the kernel ends at the limit (SIGXFSZ) is reported the same way, since the watchdog's look (Limits.pollInterval, 0.25 s for every watched run) still lets a fast writer put hundreds of megabytes on the disk between two looks.
The call runCapturingOutput(_:arguments:limits:maximumOutputBytes:...) keeps what a child prints (afinfo's).
Its standard output goes to a new hidden `.<UUID>.watched-output` file in the temporary directory.
That file is the watched file, capped at maximumOutputBytes (1 MiB unless asked otherwise) and removed however the run ends, by an exit, a kill, a failure to start, or a cancellation.
Here output is not progress, so the stall clock runs from the child's start, and a child that prints without end still ends at its time limit while one that prints only when it ends (afinfo) is not killed for being silent.
The call runStreaming(_:arguments:watching:limits:...:reading:) hands what a child writes to its standard output to a reader as it comes, through a pipe (PipeReader), for the FFmpeg helper.
Nothing is staged in a file, and the kernel's file-size limit never applies, since the child writes a pipe.
The watched file is the one the reader writes (watching: nil for none), and the reader counts its cap too.
A reader that fails gets the child killed at once; one that returns has the child end by itself within endGraceSeconds (defaultEndGraceSeconds, 2), else a SIGKILL that is not the watchdog's: its Ending is a signal, never .killed.
A reason's words (KillReason.words) count its seconds with CountWording.seconds, so a limit of one second reads "1 second".
The watchdog's clock is ProcessInfo.systemUptime, which never runs backwards, so a sleep or a change of the wall clock never ages a healthy child.
ChildGate holds the child's pid and whether its task was cancelled under one lock, so a cancellation and the child's start meet in either order and the child is killed all the same, and a task already cancelled starts no child.
Every running child is in a registry that terminateAll() kills with SIGKILL, taking a short lock and never waiting for a child.
Both applicationWillTerminate and PlaybackMemoryGuard.quitAtOnce() call it.
Its startReaper(watching:parent:) starts a /bin/sh loop that checks each second and kills the child once TextMouth's own pid is gone, however TextMouth went (quit, force-quit, or the memory guard's _exit), and ends by itself when the child does.
A reaper that cannot start is not an error for the run.

## OrphanedConversionSweep
<!-- id: orphanedconversionsweep; keys: orphan sweep, leftover afconvert, leftover afinfo, launch cleanup, libproc, stale temporary files, storage log; src: TextMouth/Platform/macOS/Services/OrphanedConversionSweep.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Platform/macOS/App/AppDelegate.swift -->

OrphanedConversionSweep (Platform/macOS/Services/OrphanedConversionSweep.swift) deals with the converters an earlier TextMouth left running.
applicationDidFinishLaunching calls sweepInBackground() once, on a utility queue and never in a hosted test.
It lists the processes through libproc, reading each command line with sysctl(KERN_PROCARGS2), and kills with SIGKILL each one that:

- is /usr/bin/afconvert,
- is run by the current user,
- is an orphan (parent pid 1), and
- has as its last argument a hidden temporary output name of TextMouth's.

That name is a last path component that starts with "." and ends with one of the suffixes ImportAudioConverter.isTemporaryName(_:) knows, with something between: .audio-conversion.m4a, the .ogg-conversion.m4a an earlier version used, and .audio-downmix.caf.
One OGG_ORPHAN_SWEPT line counts what it killed.
The second sweep, sweepAfinfoInBackground() (FMT09, also called at launch, never in a hosted test), kills with SIGKILL each /usr/bin/afinfo that:

- is run by the current user,
- is an orphan, and
- has as its standard output, descriptor 1 (ProcessSnapshot.standardOutputPath, read with proc_pidfdinfo and PROC_PIDFDVNODEPATHINFO), a hidden `.<UUID>.watched-output` file (WatchedProcess.outputFileSuffix; shouldKillAfinfo).

It also removes from the temporary directory each such regular file more than an hour old (sweepCapturedOutputFiles(in:)).
One AFINFO_LEFTOVERS_SWEPT line, in the storage category, counts what it did.

## Temporary names of conversions
<!-- id: temporary-names-conversions; keys: temporary file, .audio-conversion.m4a, long file name, exFAT, 255 units, Ogg book conversion, name collision, rename; src: TextMouth/Services/ImportAudioConverter.swift, TextMouth/ViewModels/LibraryViewModel+OggConversion.swift, TextMouth/Services/BookContentAnalysisService.swift -->

A conversion is written under the hidden name ImportAudioConverter.temporaryURL(beside:) makes, "`.<UUID>.audio-conversion.m4a`", built from the UUID alone (58 characters), so a track whose name is as long as the file system allows can be converted.
Still, removeLeftovers(in:) finds it, and a downmix's CAF and an earlier version's .ogg-conversion.m4a, by isTemporaryName(_:).
Then givingFinalName takes the track's stem with .m4a, else "STEM 2.m4a" and on, each by one RENAME_EXCL rename (renameWithoutReplacing).
Also candidateName(stem:number:) drops whole characters from the end of the stem until the name is at most 255 UTF-16 units (maximumNameLength), each candidate fitted on its own.
A file system that refuses RENAME_EXCL (exFAT answers ENOTSUP) is served by reserving the name with an exclusive create and renaming over the empty reservation.
The library's one-time conversion of its Ogg books (convertOggBooksOnce), convertOggBookAudio(ofBook:), reads a folder book's saved index (BookContentAnalysisService.load) before it converts anything, so a book whose index the commit would refuse waits with no minutes spent and no hidden file made.
Also commitTracks discards the converted files (ImportAudioConverter.discard) when it throws.

## Files of the audio the import converts
<!-- id: files-audio-import-converts; keys: file list, audio import files; src: TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/AudioFileInfo.swift, TextMouth/Services/FileImportService+AudioConversion.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Platform/macOS/Services/OrphanedConversionSweep.swift, TextMouth/Parsers/AudioContentSniffer.swift, TextMouth/Parsers/NeroChapterReader.swift, TextMouth/Parsers/M3UPlaylist.swift, TextMouth/Models/PlaylistImportWording.swift, TextMouth/Models/ConvertedOriginalWording.swift, TextMouth/Models/ImportProgressWording.swift, TextMouth/Parsers/AudioBookParser.swift, TextMouth/Parsers/AudioMediaProbe.swift, TextMouth/Services/OggHeaderReader.swift, TextMouth/Services/BookExportService.swift, TextMouth/Models/Book.swift, TextMouth/Services/FileImportService.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift, TextMouth/ViewModels/LibraryViewModel+OggConversion.swift, TextMouth/Resources/Info.plist -->

The files are the paths in this section's marker.
