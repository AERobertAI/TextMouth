# The audiobook manifest: manifest.json

Part of [TextMouth's documentation](../../README.md).

A ZIP of audio tracks becomes one audiobook in TextMouth, with a heading for each track. Without a manifest, each heading is its track's file name without the extension, in the order Finder sorts the names, counting numbers as numbers ("Track 2" before "Track 10"); tracks in folders inside the ZIP count too. A file named manifest.json in the ZIP lets you name the book, put the tracks in your own order, give each track a proper title, group tracks under headings of their own, and set the pauses between tracks.

This document is the complete reference. It is written so you can also hand it to an assistant, with your list of file names, and ask it to write the manifest for you.

## What works in which version

- **Now, in a build of main from October 13, 2026 or later:** title, author, order, and chapters, described under "The older keys" below. Ogg tracks import too.
- **With the manifest update (being built on October 13, 2026):** tracks, group headings, pauses between tracks, a manifest found inside the ZIP's one folder, and an import that stops and says what is wrong with a manifest. Until you install a build with it, a manifest using these keys is passed over without a word, and the book imports in name order.

## Where the manifest goes

- At the top level of the ZIP, beside the tracks.
- Or, with the update, inside the one folder that holds everything, when the ZIP's top level holds only that folder. Finder's Compress command makes ZIPs like that: put your tracks and manifest.json in a folder, then compress the folder.
- File names in the manifest are written as seen from the manifest's own folder, exactly, with the letters' case and the extension: "elegy.ogg", or "Disc 2/03.mp3" for a track in a folder beneath it.

## A complete example

```json
{
  "title": "The Twilight Zone Radio Dramas",
  "author": "Various",
  "pauseBetweenTracksMs": 250,
  "tracks": [
    { "heading": "Season One" },
    { "file": "where_is_everybody.ogg", "title": "Where Is Everybody?" },
    { "file": "one_for_the_angels.ogg", "title": "One for the Angels" },
    { "file": "mr_denton_on_dooms_day.ogg", "title": "Mr. Denton on Doomsday", "pauseAfterMs": 2000 },
    { "heading": "Season Two" },
    { "file": "king_nine_will_not_return.ogg", "title": "King Nine Will Not Return" },
    "the_man_in_the_bottle.ogg"
  ]
}
```

This book is called The Twilight Zone Radio Dramas, by Various. Its headings, in order:

1. Season One, a level-1 heading.
2. Where Is Everybody?, a level-2 heading under it. The first two headings start at the same moment.
3. One for the Angels, level 2.
4. Mr. Denton on Doomsday, level 2. Two seconds of silence follow it, in place of the usual quarter second.
5. Season Two, level 1, starting with the next track.
6. King Nine Will Not Return, level 2.
7. the_man_in_the_bottle, level 2: a track listed by its file name alone keeps that name, without its extension, as its title.

Any track in the ZIP that the list leaves out plays after the listed ones, in Finder's order, as a level-1 heading of its own.

## The keys

Every key is optional. A manifest is one JSON object.

### title and author
- title: the book's title. Without it, the book takes the ZIP's name.
- author: the book's author. Without it, Unknown.

### tracks (with the update)
The book's order and titles, one entry per track or group heading. An entry is one of:
- A file name, in quotation marks: the track, titled by its file name without the extension.
- A track object: `{ "file": "elegy.ogg", "title": "Elegy", "pauseAfterMs": 500 }`. Only file is required. title is what the heading shows and VoiceOver speaks; the file keeps its own name. pauseAfterMs sets the pause after this track alone.
- A group heading: `{ "heading": "Season One" }`. It becomes a level-1 heading at the start of the next track, and every track after it becomes a level-2 heading, until the next group heading. Tracks before the first group heading stay level 1.

### pauseBetweenTracksMs (with the update)
The silence between one track's end and the next track's start, in milliseconds, while the book plays on.
- The default is 250, a quarter of a second, for every book whose ZIP has a manifest. A ZIP without a manifest plays straight from one track into the next, as before, since many audiobooks split a sentence across two tracks.
- Any number from 0 (no pause) to 60000 (one minute).
- A pause lasts the same real time at every playback speed.
- There is no pause after the last track, and none when you jump: a pause comes only as one track plays on into the next.
- While a pause passes, the book is still playing: Pause pauses it at the start of the next track.

### The older keys
These still work, though tracks does their work in one place and can't be used with them.
- order: a list of file names in the order the book plays them. Tracks it leaves out play after the listed ones, in Finder's order.
- chapters: an object giving file names their titles, as in `{ "elegy.ogg": "Elegy" }`.
- segments: TextMouth writes this itself when it converts a DAISY audio book: each section is a stretch of the audio files. Leave it to TextMouth.

## Mistakes TextMouth reports (with the update)

When a manifest has a mistake, the import stops, and its alert says what is wrong and where, so you can fix the manifest and import again:
- It isn't valid JSON. The alert gives the line and column. A common cause is curly quotation marks: JSON needs straight ones ("), and TextEdit's smart quotes turn them curly. In TextEdit, choose Format, Make Plain Text, so the file is saved as text rather than rich text, and turn off Smart Quotes under Edit, Substitutions.
- A key TextMouth doesn't know, such as a misspelled "titel".
- A value of the wrong kind, such as text where a number belongs, or a pause outside 0 to 60000.
- A file name the ZIP doesn't hold, or a track listed twice.
- A tracks entry with both file and heading, or neither, and a group heading with no track after it.
- tracks used together with order, chapters, or segments.

## Writing a manifest with an assistant

1. List the ZIP's files exactly. In Terminal: `zipinfo -1 "My Tracks.zip"` prints one name per line.
2. Give the assistant this document and that list, and say what you want, for example: "Write a TextMouth manifest.json for these files. Group them by season with a heading for each, in the order the episodes first aired, and give each track its episode's title. Keep the default pause, and a two-second pause after the last track of each season."
3. Check that every file name in its answer matches the list exactly. The import names any that don't.

## Adding a manifest to a ZIP

- To a ZIP you already have: in Terminal, in the folder holding both, run `zip -j "My Tracks.zip" manifest.json`. The -j stores the manifest at the ZIP's top level. zip writes the whole archive again, which for a large ZIP takes a minute or two and needs as much free space as the ZIP.
- Or, with the update: unzip the tracks into a folder, put manifest.json in that folder, and compress the folder with Finder.
- TextMouth reads the manifest when it imports the ZIP. To change a book you have already imported, edit the manifest and import the ZIP again, then remove the old copy.
