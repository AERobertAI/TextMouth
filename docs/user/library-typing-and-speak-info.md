# Letter keys and Speak Info
<!-- id: library-typing-and-speak-info; keys: type select, type to find, summaries, Shift-Command-I; src: TextMouth/Views/Library/LibraryTitleTyping.swift, TextMouth/ViewModels/LibraryInfoSpeaker.swift -->

Part of [TextMouth's documentation](../../README.md).

## Letter keys in a Library window
<!-- id: letter-keys-library-window; keys: type-ahead, first letter, list navigation, single-key shortcuts, Shift-J; src: TextMouth/Views/Library/LibraryTitleTyping.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Models/TitleTyping.swift -->

In a Library window, a letter pressed alone moves to the first book or folder whose name starts with it.
That is the list's own letter navigation, and no shortcut takes such a key there, or in a sheet over a Library window, however the Shortcuts tab sets it.
Shortcuts that are a letter alone, W, J, K, L, F, and B by default, work in reader windows only.
Space is not a letter, so Play / Pause keeps it, except while you type a title that goes on with a space, in the two choices of the Leading articles setting that pass over articles when typing (next).
A letter with Shift, Option, Command, or Control still runs its shortcut in a Library window, as a Shift-R you gave Release Media Controls does.
Shift-J and Shift-L do not fall back to the actions of J and L there, so the list takes them (see the Shortcuts tab, in [Settings](settings-shortcuts.md)).
Speak Info and Speak Full Info do not use the letter I alone, or I pressed twice; unless you changed their keys, they follow the defaults described under Speak Info, below.

## Leading articles
<!-- id: leading-articles; keys: The Hobbit, articles, Titles section, leadingArticles, partOfTitle, config.json; src: TextMouth/Models/LeadingArticleWording.swift, TextMouth/Models/LeadingArticles.swift, TextMouth/Models/TitleTyping.swift, TextMouth/Views/Library/LibraryTitleTyping.swift, TextMouth/ViewModels/LibraryListCache.swift -->

Leading articles.
The Library tab of Settings has a Titles section whose Leading articles pop-up chooses what the words The, A, and An, and a book's own language's articles, at the start of a title do in the Library's lists (see [Settings](settings-library.md) for the choices, the languages, and config.json).
It changes nothing in a title: Book Information, a reader window, Now Playing, Speak Info, and Export keep each title as written.

- Part of the Title, the default, leaves everything as described above: the list's own letter navigation finds titles as they are written, and The Hobbit is among the T's.
- In Ignored When Typing and in Ignored When Typing and Sorting, TextMouth handles the letters typed into the list itself, so a title is reached from its first letters past its article.
  It does so only while the list itself has the keyboard: letters typed into the search field, or any other control, stay there.
  - H goes to The Hobbit, as do "ho" and "hobbit".
    "the h" goes to it too: once you have typed more than the article and its space, the letters may be the title as written.
    "the" alone goes only to titles that file under those letters, such as Theory of Everything, since more letters may follow.
    Letter case, accents, and the kind of apostrophe never matter.
    In Ignored When Typing and Sorting, whose rows show "Hobbit, The", "hobbit, t" reaches it too.
  - Letters typed within about a second and a quarter of each other (1.25 seconds) add up to one search, and a letter typed later begins another.
    A key you hold types its letter once.
  - A search that begins goes to the first matching row after the selected one, and wraps round the end of the list, so H, a pause, and H again goes on to the next title that H reaches, and walks through them in turn.
    A search that adds letters starts at the selected row, so "ha" typed after "h" stays on Hamlet.
    With nothing selected, a search starts at the top.
    A key that reaches no row leaves the selection where it was and makes no sound, and a key with Command or Control, or one that is no letter, such as an arrow, is not typing and ends the search.
  - Space joins the letters only while a title in the list goes on with the letters you typed and a space, and you typed the last of them within the same time, as "the " goes on into The Hobbit and "lord " into The Lord of the Rings.
    At any other time Space is Play / Pause, as before.
  - The row reached is selected, and the list scrolls to show it whole.
    VoiceOver follows the selection and reads the row as it reads any row, and TextMouth says nothing more.
  - The rows reached are those the list shows, in its order: the Folders section's folders, by their names as written; the Feeds section's feeds, in the order it shows them; the books, episodes, and articles listed, and, in a feed's folder, its downloaded items first, then its other books.
    A feed's item that is not downloaded has no row to select, and is not reached.
- In Ignored When Typing and Sorting, every Library list sorts titles by where they file, so The Hobbit is among the H's, and shows its row as "Hobbit, The", with the article after the main title, so a subtitle keeps its place: "Hobbit, The: There and Back Again".
  Two titles that file the same, "Hobbit" and "The Hobbit", stay apart, the one without the article first.
  - It applies to the Title sort and to every tie broken by title, in Folders, All Items, Unopened, Recently Opened, and any view of your own, and to the ties a view's limit breaks by title.
    It applies also to the Feeds section, whose feeds sort and show without their leading articles.
    It applies also to the titles a feed's items show, which stay in the feed's own order, newest first.
    It applies also to the Books rotor.
    A folder's manual order stays as you arranged it, and books you have not placed in it follow the order of their titles as this choice reads them; the Reading List keeps the order you gave it, in every choice.
  - A row's VoiceOver label, a braille display, and the Books rotor read the title as the row shows it, and so does the Folders rotor's entry for a feed whose row stands for its folder.
    A folder's name is shown and typed as written.
  - The search field finds a title as it is written or as the row shows it: in Ignored When Typing and Sorting, "hobbit, the" and "The Hobbit" both find it; it finds the author as always.
- A change of the setting takes effect at once in every open Library window.
  The iPhone shows titles as written.

## Search Library
<!-- id: typing-search-library; keys: full-text search, find in all books, Option-Command-F, regular expression; src: TextMouth/Models/LibrarySearchWording.swift, TextMouth/ViewModels/LibrarySearchModel.swift, TextMouth/App/MenuCommands.swift -->

Search Library…, in the Edit menu's Find submenu (Option-Command-F, in every window), opens a window that searches the text of every book in the library at once, with Match Case and regular expressions, and opens a match in its book at those words.
It has its own page: [Search Library](search-library.md).
Its first search after a new installation may take several seconds while TextMouth makes the search texts it keeps on this Mac (see [Speed and memory](speed-and-memory.md)).

## Speak Info
<!-- id: library-window-speak-info; keys: brief summary, Shift-Command-I, spoken summary, reading list place; src: TextMouth/ViewModels/LibraryInfoSpeaker.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Models/SummaryPress.swift, TextMouth/ViewModels/ReaderViewModel+SpeakInfo.swift -->

Speak Info, Shift-Command-I or Library menu, Speak Info (in a reader window the same key speaks that window's book, as [Reader windows](reader-windows.md) says), speaks the selected row's brief summary in TextMouth's own voice.
It uses the voice and speed set in the Voice tab of Settings, as Where Am I? speaks a position in a reader, so it works with VoiceOver off too.
A book's summary gives its title, its author unless none is known, its format, its folder or "Not in a folder", or, for a feed's episode or article, its feed, as in "In The Digital Antiquarian, a feed".
It also gives its place in the reading list, for a book in it, in every view, as in "In reading list, 3 of 12", its progress and time left as its row says them, and "Unopened" for a book never opened, as in "Middlemarch.
By George Eliot.
EPUB.
In Classics.
In reading list, 3 of 12.
42 percent.
2 hours, 5 minutes remaining."
A folder's gives its name, "Folder", its books, in it and in every folder inside it, with how many are unopened, and its feeds, when it holds any.
A feed's gives its title, "Feed", "Unsubscribed" while you are unsubscribed from it, "Folder missing" when its folder is gone, and its items counted as its row counts them (see Feeds in the library, under [Podcasts and article feeds](feeds.md)).
It also gives its last check, or, for a feed you unsubscribed from, since when it hasn't been checked, as in "Finish It!.
Feed.
Unsubscribed.
10 of 381 episodes listed.
Not checked since", then the day and time of the last check.
With nothing selected it says "Nothing is selected."

## Speak Full Info
<!-- id: speak-full-info; keys: full summary, double press, Where Am I? Full Summary, SummaryPress; src: TextMouth/Models/SummaryPress.swift, TextMouth/ViewModels/LibraryInfoSpeaker.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift -->

Speak Full Info, Shift-Command-I pressed twice quickly or Library menu, Speak Full Info, speaks the selected row's full summary: the first Shift-Command-I starts the brief summary at once, and a second within the double-press time (see the Shortcuts tab, below) switches to the full one.
A press of Shift-Command-I while a summary speaks stops it, as Speak Full Info does while the full one speaks, and Shift-Command-I on another row while a summary speaks speaks that row's summary instead, or, with nothing selected, says "Nothing is selected."
However soon it follows the last summary, Shift-Command-I speaks the brief one: a quick third press does not reach the full summary.

### Where Am I? in a reader
<!-- id: where-am-i-reader; keys: W twice, Playback menu, reader toolbar, Actions menu; src: TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/Models/SummaryPress.swift -->

Where Am I? works the same way in a reader, with W and W twice, Where Am I?
Full Summary, which the Playback menu offers too, as does the reader toolbar's Where Am I? button among its actions in VoiceOver's Actions menu (VO-Command-Space): the book stays paused, with no second start sound, until the full summary ends.

### Play and Pause during the announcement
<!-- id: play-pause-during-announcement; keys: AirPods, media key, Release Media Controls, resume, announcement paused; src: TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

Play/Pause pressed while Where Am I? speaks, from the keyboard, the AirPods, or a media key, a Pause from the AirPods or a media key, and the book's sleep timer running out end the announcement without resuming the book.
And so do the AirPods disconnecting, a recording starting, and another book starting while the book counts as playing, as it does while the announcement holds it paused or holds a Play for it (below).
A book the announcement paused then stays paused as any pause leaves it: no time after it counts as listening, a sleep timer's countdown waits for Play, and an audiobook's Play/Pause button says Play.
A Play from the AirPods, a media key, or Control Center while Where Am I? speaks waits for it: a book the announcement paused plays again as it ends, and a book paused or stopped before it starts once its end sound has played, with the play sound.
Until the book plays again, it still counts as playing: a sleep timer running out, a Pause from the AirPods or their leaving, a recording or another book starting, or Play/Pause in that moment leaves it paused.
And Where Am I? pressed in the moment after the announcement has ended, before the book plays again, keeps it paused until the new announcement ends, while a skip in that moment resumes it at once.
Over a book paused or stopped before the announcement began, with no Play pressed, the announcement goes on when another book starts.
Release Media Controls ends the announcement with the book, so the book stays stopped and the AirPods stay released, and so does anything else that stops the book, as a chapter that can't be downloaded or played does.

### Jumps and the speech engine
<!-- id: jumps-speech-engine; keys: Next Heading, Previous Heading, Auto-play on navigate, jump, speech cancelled; src: TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/ViewModels/ReaderViewModel+Jump.swift -->

A jump while Where Am I? speaks, by Next Heading or Previous Heading, a heading, bookmark, or search result picked from its list, Go to a percent or a time, or Return to previous position, ends the announcement as a skip does.
A book it paused plays on from where the jump lands, and a book a Play was pressed for starts there.
With Auto-play on navigate, a heading, bookmark, or search result picked from its list also plays a book paused or stopped before the announcement, from where the jump lands.
Should the speech engine cancel the announcement before it ends, whatever waited for it starts as the announcement's end would have started it:
- a book you pressed Play for during the announcement, the one it paused included
- a chapter whose files arrived during it
- a book waiting for its chapter's speech, at once or as soon as the speech is ready

With no Play pressed, the book the announcement paused stays paused, and Play/Pause resumes it.

### A book waiting to start
<!-- id: book-waiting-start; keys: end sound, pause between chapters, waiting for speech, chapter files; src: TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift -->

Play/Pause during Where Am I? also pauses, without the pause sound, a book waiting to start, as it does without the announcement: one waiting for its chapter's speech, for a chapter's files to download, or for the library to finish moving it.
A Play pressed while Where Am I?'s end sound plays changes nothing: the book, or a chapter whose files arrived during the announcement, starts once the end sound has played, with no play sound.
A pause between two chapters of an audiobook that ends during the end sound, or speech that a Play was waiting for becoming ready then, is held for the sound as well: the book goes on counting as playing, and plays once the sound has passed.

### Sound output, Edit Text, the sleep timer, and the cloud
<!-- id: sound-output-edit-text-sleep; keys: AirPods connect, library move, cloud download, Edit Text, sleep timer; src: TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift -->

If the sound output changes while Where Am I? speaks over a book it paused, as when AirPods connect, or the library moves that audiobook's files meanwhile, the book plays on afresh from where it paused once the announcement ends, on the new output or from the files' new place.
A text book keeps speaking in the voice.
Edit Text taken while Where Am I? speaks over a playing book ends the announcement, and the book plays on in the edited text from its place.
Setting a sleep timer while Where Am I? speaks lets the announcement finish and plays the book as it ends.
In a library in the cloud, a chapter whose files arrive while Where Am I? speaks plays once the announcement has ended, even if the library moves the book meanwhile, from the book's new place.

### What the full summary adds
<!-- id: what-full-summary-adds; keys: date added, last opened, bookmarks, braille code, file size, Text encoding sentence; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/LibraryInfoSpeaker.swift -->

A book's full summary adds:
- when it was added and last opened
- its bookmarks
- a braille book's code, said right after the bookmarks as "Braille code: Unified English Braille, contracted (Grade 2)"
- for a BRF or BRL book, its braille file characters right after the code, as "Braille characters: North American Braille ASCII"
- its file size, unless its files are in the cloud, which are never downloaded to measure them
- its cloud note and whether it is kept on this Mac
- whether a reader window has it open

A folder's adds its subfolders and the time left in all its books.
A feed's adds its folder and its address.
The full summary of a text book that records an encoding, guessed or chosen (see [What TextMouth reads](reads-text-files.md)), says so right after the bookmarks.
The sentence is "Text encoding: Windows-1251 (Cyrillic), guessed." or "Text encoding: Shift JIS (Japanese), chosen."
The brief summary does not, and a book that records no encoding has no such sentence, since Speak Full Info never reads a book's file to find one.

### Text fields and the Shortcuts tab
<!-- id: text-fields-shortcuts-tab; keys: Shortcuts tab, Information group, text field, key conflict; src: TextMouth/Models/KeyboardShortcut.swift, TextMouth/Services/KeyboardShortcutManager.swift -->

Shift-Command-I has Command in it, so it works from the search field, or any text field, as Command-I does.
The Shortcuts tab lists Speak Info and Speak Full Info under Information, after Where Am I? and Where Am I?
Full Summary, and leaves either without a key while you have given its key to another action.
