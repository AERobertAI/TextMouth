# Exporting a transcript as captions
<!-- id: export-transcript-captions; keys: VTT, SRT, captions, subtitles; src: TextMouth/Services/Export/TimedTextWriters.swift, TextMouth/Models/BookExportWording.swift -->

Part of [TextMouth's documentation](../../README.md).

Part of version 0.4.2.

## The Convert transcript to pop-up
<!-- id: export-convert-transcript-pop-up; keys: Convert transcript to, Transcript checkbox; src: TextMouth/Models/BookExportWording.swift, TextMouth/Views/Export/BookExportSheet.swift -->

The Transcript checkbox has its own pop-up, "Convert transcript to", so it never sounds like the "Convert to" pop-up of the text (see [Exporting books](exporting-books.md)).
VoiceOver reaches it right after the checkbox.

## The transcript's choices
<!-- id: export-transcript-choices; keys: JSON, WebVTT, SubRip, text writers; src: TextMouth/Models/BookExportWording.swift, TextMouth/Services/Export/TimedTextWriters.swift -->

Its choices are JSON and Markdown, then each text writer, such as HTML, RTF, or EPUB, then WebVTT and SubRip.

## JSON and Markdown
<!-- id: export-transcript-json; keys: transcript.json, default transcript export; src: TextMouth/Models/BookExportWording.swift, TextMouth/Services/BookExportService.swift -->

JSON and Markdown is the first choice and the default.
It gives the transcript as TextMouth keeps it.

## A text writer for a transcript
<!-- id: export-transcript-as-text; keys: HTML, RTF, EPUB, transcript text; src: TextMouth/Models/BookExportWording.swift, TextMouth/Services/BookExportService.swift -->

A text writer writes the transcript's text, made from the Markdown TextMouth reads it from, as it does for the text of a book.
EPUB is among them.

## WebVTT
<!-- id: export-webvtt; keys: .vtt, UTF-8, WebVTTWriter; src: TextMouth/Services/Export/TimedTextWriters.swift, TextMouth/Models/BookExportWording.swift -->

WebVTT: "Captions in WebVTT, which web browsers and most players read: one file, timed from the start of the audio."

## SubRip
<!-- id: export-subrip; keys: .srt, byte-order mark, CR LF, SubRipWriter; src: TextMouth/Services/Export/TimedTextWriters.swift, TextMouth/Models/BookExportWording.swift -->

SubRip: "Captions in SubRip (.srt), which nearly every player reads: one file, timed from the start of the audio."

## The checkbox for captions
<!-- id: export-captions-checkbox; keys: Transcript as WebVTT, no size, file count; src: TextMouth/Models/BookExportWording.swift, TextMouth/Views/Export/BookExportSheet.swift -->

While captions are chosen, the checkbox reads "Transcript as WebVTT", with no size and no file count.
A WebVTT file is plain UTF-8.
A SubRip file begins with the UTF-8 byte-order mark and ends each line with CR LF.

## SubRip's escapes
<!-- id: export-subrip-escapes; keys: character references, greater-than sign, less-than sign, ampersand escape; src: TextMouth/Services/Export/TimedTextWriters.swift -->

SubRip has no standard way to escape text, so TextMouth writes as character references the few strings that a player or reader would take for something else, and TextMouth's reader decodes them:

- the ">" that ends "-->", as &gt;;
- a "<" with a ">" after it, which would look like a tag, as &lt;;
- a "{" followed by a backslash, as &#123;;
- an "&" that begins what a reader would decode, as &amp;.

## Players that show the references as written
<!-- id: export-subrip-players; keys: raw references, player display; src: TextMouth/Services/Export/TimedTextWriters.swift -->

Other players may show those references as written.

## A transcript with no times
<!-- id: export-captions-no-times; keys: Couldn't export, untimed transcript, Markdown-only transcript; src: TextMouth/Models/BookExportWording.swift, TextMouth/Services/BookExportService.swift -->

A transcript that keeps its text and no times, such as one that holds only Markdown, can't be written as captions.
The export says "Couldn't export … - Transcript.vtt: The book has no timed transcript to write as captions."

## A transcript only in the cloud
<!-- id: export-transcript-in-cloud; keys: not downloaded, Download Now; src: TextMouth/Models/BookExportWording.swift, TextMouth/Services/BookExportService.swift -->

A transcript only in the cloud is not downloaded.
The export names the book, as in "Moby-Dick isn't downloaded.
Download it first: select it in the library, then choose Download Now."
