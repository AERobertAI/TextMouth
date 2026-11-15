# What TextMouth reads: audiobooks
<!-- id: reads-audiobooks; keys: audio formats, M4B, MP3, convert, afconvert; src: TextMouth/Parsers/AudioBookParser.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Models/Book.swift -->

Part of [TextMouth's documentation](../../README.md).

## Single audio and video files
<!-- id: single-audio-video-files; keys: MP3, M4A, M4B, WAV, AIFF, FLAC, ALAC, MP4; src: TextMouth/Models/Book.swift, TextMouth/Parsers/AudioBookParser.swift, TextMouth/Services/AudioFileInfo.swift -->

- TextMouth plays single files in MP3, M4A, M4B, WAV (RF64 and BWF too), AIFF, FLAC, ALAC, or AAC format, and video files in MPEG-4 (.mp4), M4V, or QuickTime (.mov) format, whose sound alone plays.
- It plays these as they are, except an MPEG-4 or QuickTime file whose sound is not AAC, Apple Lossless, or MP3, which it converts like the audio below.

## Audio that TextMouth converts as it is imported
<!-- id: audio-that-textmouth-converts-as; keys: afconvert, afinfo, Ogg, AC-3, AMR, MP2, CAF, Wave64; src: TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/FileImportService+AudioConversion.swift, TextMouth/Models/ConvertedOriginalWording.swift -->

- TextMouth converts audio as it is imported, since macOS can decode it but TextMouth does not play it as it is, in these formats:
  - Ogg (.ogg, .oga, or .opus, holding Vorbis, Opus, or FLAC audio).
  - AC-3 (.ac3).
  - E-AC-3 (.ec3, .eac3).
  - MP1 and MP2 (.mp1, .mp2, .mpa).
  - AMR (.amr, .awb).
  - 3GPP audio (.3gp, .3g2, .3ga).
  - NeXT/Sun audio (.au, .snd).
  - AIFC (.aifc).
  - CAF (.caf).
  - Wave64 (.w64).
- Each file becomes an .m4a file in the book's package, and only that file is played.
- A file is converted wherever it comes from: a single file, a ZIP, a folder, a playlist, or a feed's episode.
- The book's package keeps only the converted file, unless Keep originals of converted audio is on in the Storage tab of Settings (see [Settings](settings.md)).

### What a file holds decides
<!-- id: audio-content-decides; keys: sniffing, extension, Ogg named m4a, header length, sample rate, tags; src: TextMouth/Parsers/AudioContentSniffer.swift, TextMouth/Services/OggHeaderReader.swift, TextMouth/Parsers/AudioMediaProbe.swift -->

- What a file holds decides, not its extension.
- An Ogg file named .m4a, or an MP2 feed episode saved as .mp3, is converted all the same.
- TextMouth does not open an Ogg file under another name, an .mp3 or .m4a, with Apple's audio code to read its tags: it reads them from the file's own bytes, and names the book for the file when they can't be read.
- An audio file whose header claims an absurd length, past a year, or an absurd sample rate is refused rather than crashing the import.

### Lossy audio
<!-- id: lossy-audio; keys: AAC, Apple Lossless, bit rate, ALAC, kbit/s, lossless; src: TextMouth/Services/ImportAudioConverter.swift -->

- Lossy audio becomes AAC at about its own bit rate: it stays near its size, but a second lossy encoding can lose a little.
- The rate is the next standard AAC rate at or above the source's average (64 to 192 kbit/s for stereo, half that for mono).
- Lossless audio that TextMouth converts (PCM in CAF, AIFC, AU, or Wave64; Apple Lossless or FLAC in CAF; Ogg FLAC) becomes Apple Lossless at its own bit depth (16, 20, 24, or 32 bits) and loses nothing.
- Plain WAV, AIFF, and FLAC files are not converted at all.

### Channels
<!-- id: converted-audio-channels; keys: stereo mix, downmix, 5.1, centre channel, quieter, channel layout; src: TextMouth/Services/ImportAudioConverter.swift -->

- TextMouth writes at most two channels, so audio of more than two channels is mixed to stereo as it is converted, with Apple's standard mix: the centre channel, where speech usually is, keeps its place in both ears.
- Such a book plays about 11 to 14 dB quieter than a stereo book: 11 when the source is linear PCM and 14 when it is AC-3.
- A file of more than two channels that does not say which is which can't be mixed, and is refused.

### Ogg audio
<!-- id: ogg-audio; keys: Vorbis, Opus, Ogg FLAC, Skeleton, OggHeaderReader, macOS 15.4, hang; src: TextMouth/Services/OggHeaderReader.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/ViewModels/ReaderViewModel+OggConversion.swift -->

- TextMouth converts Ogg audio on macOS 15.4 and later, which can read it.
- It never plays Ogg itself, since macOS's Vorbis decoder can lock up while playing.
- It does not ask macOS's audio to open an Ogg file for anything else either: it reads the file's title, artist, album, genre, year, and length from the file's own bytes with code of its own, and only afconvert, run as a separate process that TextMouth watches, decodes it.
- An Ogg file that claims to last more than a year is refused as unreadable.
- A file cut from a longer stream, as a live broadcast joined part way through is, reports the length it holds, not the length counted from the start of the broadcast.
- A file that carries an Ogg Skeleton track beside its audio is read for its audio and imports like any other.

### Every other converted format
<!-- id: every-other-converted-format; keys: afinfo, afconvert, WatchedProcess, unreadable, claimed length; src: TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/AudioFileInfo.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift -->

- Every other converted format is read by Apple's afinfo tool, which says what the file holds, and then converted by afconvert, each run as a separate process that TextMouth watches (see [Where TextMouth keeps your library](where-your-library-lives.md)).
- A file of one of them that claims to last more than a year, or a length that its size cannot hold, is refused as unreadable.
- A Mac that can't read or convert a format refuses a file of it by name when it is imported, and nothing is added.

## Chapter lists in Nero format
<!-- id: chapter-lists-nero-format; keys: Nero chapters, chpl, M4B chapters, untitled chapter; src: TextMouth/Parsers/NeroChapterReader.swift -->

- An M4B, M4A, MP4, M4V, or MOV file whose only chapter list is a Nero list (some audiobook tools write only that) has its chapters as headings, an untitled one called "Chapter" and its number.

## M3U and M3U8 playlists
<!-- id: m3u-m3u8-playlists; keys: .m3u, .m3u8, playlist, track order; src: TextMouth/Parsers/M3UPlaylist.swift, TextMouth/Models/PlaylistImportWording.swift -->

- An M3U or M3U8 playlist (.m3u, .m3u8) becomes one audiobook of the files it lists, a heading for each, in the playlist's order (see [Adding books](adding-books.md)).

## A ZIP of audio tracks
<!-- id: zip-audio-tracks; keys: manifest.json, Finder Compress, track titles, groups, pauses, ZIP; src: TextMouth/Parsers/AudioManifest.swift, TextMouth/Parsers/AudioBookParser.swift, TextMouth/Services/FileImportService.swift -->

- A ZIP of audio tracks becomes one book with a heading for each track.
- A manifest.json in the ZIP, at its top level or inside the one folder that holds everything, as Finder's Compress command makes it, can name the book and its author, put the tracks in your order with titles of their own, group them under headings, and set the pauses between them.
- An import whose manifest has a mistake stops and says what is wrong and where (see [The audiobook manifest](audiobook-manifest.md)).

## A DAISY audio book in a ZIP
<!-- id: daisy-audio-book-zip; keys: DAISY audio, SMIL, narration, section audio; src: TextMouth/Parsers/DAISYParser+Audio.swift, TextMouth/Parsers/DAISYParser+SMILParser.swift -->

- A DAISY audio book in a ZIP becomes one audiobook whose sections are its headings.
- A section plays all of its heading's narration, even where it runs on into other audio files.
- A DAISY audiobook imported by an earlier version keeps one stretch of audio per section until it is imported again.
