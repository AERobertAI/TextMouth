# Exporting a transcript as captions
<!-- id: transcript-as-captions; keys: ; src: -->

Part of version 0.4.2.

## The Convert transcript to pop-up
<!-- id: convert-transcript-pop-up; keys: ; src: -->

The Transcript checkbox has its own pop-up, "Convert transcript to", so it never sounds like the "Convert to" pop-up of the text.
VoiceOver reaches it right after the checkbox.

## The transcript's choices
<!-- id: transcript-choices; keys: ; src: -->

Its choices are JSON and Markdown, then each text writer, such as HTML, RTF, or EPUB, then WebVTT and SubRip.

## JSON and Markdown
<!-- id: json-markdown; keys: ; src: -->

JSON and Markdown is the first choice and the default.
It gives the transcript as TextMouth keeps it.

## A text writer for a transcript
<!-- id: text-writer-transcript; keys: ; src: -->

A text writer writes the transcript's text, made from the Markdown TextMouth reads it from, as it does for the text of a book.
EPUB is among them.

## WebVTT
<!-- id: webvtt; keys: ; src: -->

WebVTT: "Captions in WebVTT, which web browsers and most players read: one file for the book, timed from the start of its audio."

## SubRip
<!-- id: subrip; keys: ; src: -->

SubRip: "Captions in SubRip (.srt), which nearly every player reads: one file for the book, timed from the start of its audio."

## The checkbox for captions
<!-- id: checkbox-captions; keys: ; src: -->

While captions are chosen, the checkbox reads "Transcript as WebVTT", with no size and no file count.
A WebVTT file is plain UTF-8.
A SubRip file begins with the UTF-8 byte-order mark and ends each line with CR LF.

## SubRip's escapes
<!-- id: subrip-escapes; keys: ; src: -->

SubRip has no standard way to escape text, so TextMouth writes as character references the few strings that a player or reader would take for something else, and TextMouth's reader decodes them:

- the ">" that ends "-->", as &gt;;
- a "<" with a ">" after it, which would look like a tag, as &lt;;
- a "{" followed by a backslash, as &#123;;
- an "&" that begins what a reader would decode, as &amp;.

## Players that show the references as written
<!-- id: players-that-show-references-as; keys: ; src: -->

Other players may show those references as written.

## A transcript with no times
<!-- id: transcript-no-times; keys: ; src: -->

A transcript that keeps its text and no times, such as one that holds only Markdown, can't be written as captions.
The export says "Couldn't export … - Transcript.vtt: The book has no timed transcript to write as captions."

## A transcript only in the cloud
<!-- id: transcript-only-cloud; keys: ; src: -->

A transcript only in the cloud is not downloaded.
The export names the book, as in "Moby-Dick isn't downloaded.
Download it first: select it in the library, then choose Download Now."
