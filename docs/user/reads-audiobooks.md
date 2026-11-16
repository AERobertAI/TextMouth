# What TextMouth reads: audiobooks
<!-- id: reads-audiobooks; keys: audio formats, M4B, MP3, convert, afconvert; src: TextMouth/Parsers/AudioBookParser.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Models/Book.swift -->

Part of [TextMouth's documentation](../../README.md).
Every format TextMouth reads, with how well each is tested, is in [the list of formats](formats-list.md).

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
- The book's package keeps only the converted file, unless Keep originals of converted audio is on in the Storage tab of Settings (see [Settings](settings-storage.md)).

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

- Every other converted format is read by Apple's afinfo tool, which says what the file holds, and then converted by afconvert, each run as a separate process that TextMouth watches (see [Where TextMouth keeps your library](helper-programs.md)).
- A file of one of them that claims to last more than a year, or a length that its size cannot hold, is refused as unreadable.
- A Mac that can't read or convert a format refuses a file of it by name when it is imported, and nothing is added.

## Chapter lists in Nero format
<!-- id: chapter-lists-nero-format; keys: Nero chapters, chpl, M4B chapters, untitled chapter; src: TextMouth/Parsers/NeroChapterReader.swift -->

- An M4B, M4A, MP4, M4V, or MOV file whose only chapter list is a Nero list (some audiobook tools write only that) has its chapters as headings, an untitled one called "Chapter" and its number.

## Chapters from markers, cue sheets, and label files
<!-- id: chapters-markers-cue-sheets-labels; keys: CUE sheet, .cue, WAV markers, BWF, AIFF markers, Ogg CHAPTER comments, Audacity labels, CD rip; src: TextMouth/Parsers/FileChapterReaders.swift, TextMouth/Parsers/CueSheet.swift, TextMouth/Parsers/CueSheetArrangement.swift, TextMouth/Parsers/AudacityLabels.swift, TextMouth/Services/AudioMarkerList.swift, TextMouth/Models/CueSheetWording.swift -->

- A single audio file's chapters become its headings from the place its kind keeps them:
  - a WAV file's cue points and labels (a Broadcast Wave file's too) and an AIFF file's markers;
  - a FLAC file's CUESHEET block, or a cue sheet kept as text in its CUESHEET comment, when the file has no CHAPTER comments;
  - the CHAPTERnnn comments of an Ogg file, and the markers of a CAF file, which are kept in the .m4a that the import converts the file to (see below).
- A marker with no name is called "Chapter" and its number.
- The sound before the first marker, when it is not at the start, is a heading of its own, named for the book.
- A file whose list makes only one heading keeps the book's title, not "Track 1" or "Chapter 1".
- A WAV or AIFF file whose only marker is at 0 seconds has no chapters.
- A converted file's chapters are written into its .m4a as its chapter track without re-encoding the sound.
  If that fails, the book is imported without chapters, and the debug log says so with AUDIO_CHAPTERS_NOT_KEPT.
- A CUE sheet (.cue) lists where each track of a CD rip, or a one-file audiobook, begins in the audio files it names.
  - TextMouth reads the FILE, TRACK, TITLE, PERFORMER, and INDEX 01 lines (INDEX 00 is ignored: the gap before a track plays as the end of the track before).
  - Each track is a heading, titled "Track" and its number when the sheet gives it no title, or its title, a comma, "by", and its performer when its performer is not the book's author, as in "Moonlight, by Ada Okafor".
  - The sheet's title and performer become the book's title and author.
  - A sheet may be UTF-8 (with or without a byte-order mark), UTF-16, or Windows-1252 or Latin-1, and up to 1 MiB.
  - It uses only files inside its own folder; a name outside it is skipped, and the notice says it is "outside the cue sheet's folder".
  - A name that is missing, outside, or not audio falls back to the audio file with the same name beside the sheet (a sheet that names album.wav for an album.flac), and a sheet of one FILE line to the audio file with the sheet's own name.
- An Audacity label file, a .txt file of labels and nothing else, beside a folder's audio gives that audio its headings, one for each label, in the order of their starts.
  - It belongs to the audio file with its name, or to the only audio file beside it.
  - A label with no text is called "Label" and its number.
  - A .txt file chosen on its own still imports as a text book, and a ZIP holding one still imports as a batch of books.
- How a sheet or label file arrives is in [Adding books](adding-books.md).
- A sheet or label file whose times run past the end of its audio is left unused, with a notice, and the tracks import without its headings.

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
