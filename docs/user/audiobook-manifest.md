# The audiobook manifest: manifest.json

Part of [TextMouth's documentation](../../README.md).

A ZIP of audio tracks becomes one audiobook in TextMouth, with a heading for each track. Without a manifest, each heading is its track's file name without the extension, in the order Finder sorts the names, counting numbers as numbers ("Track 2" before "Track 10"); tracks in folders inside the ZIP count too. A file named manifest.json in the ZIP lets you name the book, put the tracks in your own order, give each track a proper title, group tracks under headings of their own, and set the pauses between tracks.

This document is the complete reference. It is written so you can also hand it to an assistant, with your list of file names, and ask it to write the manifest for you.

## What works in which version

- **In a build of main from October 14, 2026 or later:** everything this document describes, including editing an imported audiobook's manifest where it is, and importing a plain folder of tracks.
- **In an older build:** TextMouth reads only title, author, order, and chapters. It takes a manifest's title and author, passes over tracks and the pauses, so the book imports in name order, and doesn't look inside the ZIP's one folder. Before October 13, 2026, Ogg tracks don't import at all.

## Where the manifest goes

- At the top level of the ZIP, beside the tracks.
- Or inside the one folder that holds everything, when the ZIP's top level holds only that folder. Finder's Compress command makes ZIPs like that: put your tracks and manifest.json in a folder, then compress the folder. Hidden files and Finder's __MACOSX folder don't count against the one folder; any other file or folder beside it does. A manifest at the top level is the one read, even when the one folder holds another.
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
2. Where Is Everybody?, a level-2 heading under it. The first two headings start at the same moment, so Next Heading stops there once and says both, the group first: "Heading: Season One, Where Is Everybody?"
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

### tracks
The book's order and titles, one entry per track or group heading. An entry is one of:
- A file name, in quotation marks: the track, titled by its file name without the extension.
- A track object: `{ "file": "elegy.ogg", "title": "Elegy", "pauseAfterMs": 500 }`. Only file is required. title is what the heading shows and VoiceOver speaks; the file keeps its own name. pauseAfterMs sets the pause after this track alone.
- A group heading: `{ "heading": "Season One" }`. It becomes a level-1 heading at the start of the next track, and every track after it becomes a level-2 heading, until the next group heading. Tracks before the first group heading stay level 1.
- A title that is empty or only spaces shows the file's name. A group heading takes heading alone: a title or pauseAfterMs on one, an empty heading, and an empty file name are mistakes the import reports.

### pauseBetweenTracksMs
The silence between one track's end and the next track's start, in milliseconds, while the book plays on.
- The default is 250, a quarter of a second, for every book whose ZIP has a manifest, whether it uses tracks or the older order and chapters, and for books imported earlier with a manifest too, from this update on. A ZIP without a manifest plays straight from one track into the next, as before, since many audiobooks split a sentence across two tracks.
- Any number from 0 (no pause) to 60000 (one minute).
- A pause lasts the same real time at every playback speed.
- There is no pause after the last track, and none when you jump: a pause comes only as one track plays on into the next. A jump made during a pause plays the place you chose once the pause is over.
- While a pause passes, the book is still playing: Pause pauses it at the start of the next track. A pause that ends while Where Am I? is speaking waits for the announcement to end.
- The gap you hear is the pause plus about a quarter of a second while the next track starts.

### The older keys
These still work, though tracks does their work in one place and can't be used with them.
- order: a list of file names in the order the book plays them. Tracks it leaves out play after the listed ones, in Finder's order. A file listed twice in order counts once.
- chapters: an object giving file names their titles, as in `{ "elegy.ogg": "Elegy" }`.
- segments: TextMouth writes this itself when it converts a DAISY audio book: each section is a stretch of the audio files. Leave it to TextMouth.

## Mistakes TextMouth reports

When a manifest has a mistake, the import stops at the first one, and its alert says what is wrong and where, as in "Could not import “My Tracks.zip”. Reading its manifest failed: manifest.json …". Fix it and import again; a later mistake, if there is one, is named then. The import checks:
- It isn't valid JSON, or isn't one JSON object. The alert gives the line and column, counted from 1, as an editor shows them. A common cause is curly quotation marks: JSON needs straight ones ("), and TextEdit's smart quotes turn them curly, so the alert says so when the file holds any. A file saved as rich text is named as such. In TextEdit, choose Format, Make Plain Text, so the file is saved as text rather than rich text, and turn off Smart Quotes under Edit, Substitutions.
- A key TextMouth doesn't know, such as a misspelled "titel". The alert lists the keys it knows.
- A value of the wrong kind, such as text where a number belongs, or a pause outside 0 to 60000, named with its entry's number in tracks or order.
- A file name the ZIP doesn't hold, in tracks, order, or chapters, including one that differs only in capital letters, and a file that isn't audio, such as a cover picture. The first five are named, then how many more. A track listed twice in tracks is a mistake too.
- A tracks entry with both file and heading, or neither, and a group heading with no track after it.
- tracks used together with order, chapters, or segments.

## Writing a manifest with an assistant

1. List the ZIP's files exactly. In Terminal: `zipinfo -1 "My Tracks.zip"` prints one name per line.
2. Give the assistant this document and that list, and say what you want, for example: "Write a TextMouth manifest.json for these files. Group them by season with a heading for each, in the order the episodes first aired, and give each track its episode's title. Keep the default pause, and a two-second pause after the last track of each season."
3. Check that every file name in its answer matches the list exactly. The import names any that don't.

## Adding a manifest to a ZIP

- To a ZIP you already have: in Terminal, in the folder holding both, run `zip -j "My Tracks.zip" manifest.json`. The -j stores the manifest at the ZIP's top level. zip writes the whole archive again, which for a large ZIP takes a minute or two and needs as much free space as the ZIP.
- Or unzip the tracks into a folder, put manifest.json in that folder, and compress the folder with Finder.
- TextMouth takes the title, author, order, titles, and headings when it imports the ZIP, and reads the pauses again each time the book opens. To change a book you have already imported, edit its manifest with Edit Manifest in Default Editor, or edit it in Finder (both below); there is no need to import it again.

## Editing an imported book's manifest

- An audiobook imported from a ZIP or a folder of tracks keeps its tracks and its manifest in its package. To change its order, titles, groups, or pauses, choose Edit Manifest in Default Editor or Edit Manifest With… from its reader's Book menu, or from its row's context menu in the Library window.
- The first time, TextMouth explains what will happen. The manifest opens in your default app for JSON, or in the app you choose.
- A book imported without a manifest is given one first: its tracks in the order they play, each with its heading's title, its title and author, and "pauseBetweenTracksMs": 0, so it still plays straight on from track to track.
- Each time you save, TextMouth checks the manifest as an import does. A mistake changes nothing: VoiceOver says "Manifest not updated" and the mistake, in the import's words, and the book keeps its headings until you save again. A good manifest rearranges the book, and VoiceOver says "Manifest updated", or says it when you come back to TextMouth.
- Your place, bookmarks, and skipped headings stay on their tracks, at the same time into each; titles and group headings change only the headings.
- A book open in a reader shows its new headings at once. One that is playing plays on without a break, then goes on to the next track in the new order.
- The manifest's title and author are the book's: an edited manifest's become the book's, and a title or author you change in Book Info is written into the manifest at once.
- The first time this version opens a library, a title or author you changed in Book Info before October 14, 2026, and that is recorded as yours, is written into the book's manifest, so it stays the book's; after that, a title or author changed in the manifest outside TextMouth becomes the book's.
- A manifest can't add or remove tracks, and can't give segments.
- You can also edit manifest.json yourself, in any editor, without the command. In Finder, choose Go to Folder… (Command-Shift-G) and go to the data directory, ~/.TextMouth unless you moved it, since a folder whose name starts with a dot is hidden. Open Library and the book's folder, choose Show Package Contents on the book's package (the folder ending in .tmb, named after its title, author, date added, and identifier), and open its audio folder. A book imported from a ZIP whose tracks were in one folder keeps its manifest inside that folder.
- An edit made that way, in a library in the cloud on another Mac, or while TextMouth was closed, works as well as one made through Edit Manifest, with the same checks, the same announcements, and your place and bookmarks kept on their tracks. TextMouth notices it when the book opens, before it shows, so the book opens rearranged; when TextMouth becomes active while the book is open in a reader, including an edit of its pauses alone; and once at each launch.
- TextMouth compares the manifest with the book, not its date, so a manifest that arranges the book as it shows, with its title and author, changes nothing. A book whose files are only in the cloud is looked at once they are on this Mac. A manifest that can't be read at all is a mistake, which VoiceOver says once each time TextMouth runs.
