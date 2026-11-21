# When a book ends, and your saved places
<!-- id: reader-book-end-page; keys: end of book, continue to next book, loop, finished, saved places, reading list; src: TextMouth/Models/EndOfBookRule.swift, TextMouth/Models/EndOfBookWording.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

Part of [TextMouth's documentation](../../README.md).

The reader window itself, its menus, and search are in [Reader windows](reader-windows.md).

## When a book ends
<!-- id: reader-when-book-ends; keys: When book ends, end-of-book setting, Stop, Loop to Start, Continue to Next Book, Play Starts Over, EndOfBookRule; src: TextMouth/Models/EndOfBookRule.swift, TextMouth/Models/ListeningOptions.swift, TextMouth/Models/EndOfBookWording.swift -->

When a book ends, TextMouth stops, starts the book again, or continues to the next book in the folder, as Playback settings say under When book ends: Stop, the default; Stop, and Play Starts Over; Loop to Start; or Continue to Next Book.
Four settings can decide, the first that applies winning:

- First, a book read from the reading list follows the list instead (below).
- Second, each book can override that choice in its own settings (see [A book's own settings](reader-windows.md#a-books-own-settings)).
  The settings sheet's picker, When this book ends, which VoiceOver calls "End of book behavior for this book", names the choice in force, and names Continue to Next Book whether the book's feed or folder plays the book below or the one above.
  Use Global Default, which VoiceOver calls "Reset to global end-of-book setting" and which shows only while the book has a choice of its own, removes the book's own choice, so that the choice of its feed or folder applies, or the global setting where it has none.
- Third, a feed and a plain folder each choose for their own books with a pop-up button, "When an episode ends" in Feed Info and "When a book ends" in Folder Settings (see [Podcasts and article feeds](feed-listening-and-settings.md) and [The Library window](library-window.md)).
  Its choices are Play the book below, which is Continue to Next Book; Play the book above, which is Continue to Next Book going up the list or folder instead of down; Stop; and Use the global setting, which leaves the choice to the Playback tab.
  A feed says episode in place of book, or article or item when its items are those.
  A folder's choice applies to the books directly in it, never to those in the folders inside it, and the top of the library has none.
- Last, the global setting, When book ends in the Playback tab, decides.

## Skip finished
<!-- id: reader-skip-finished; keys: finished books, play the book below, play the book above, folder end, no more books; src: TextMouth/Models/EndOfBookRule.swift, TextMouth/Models/ListeningOptionsWording.swift, TextMouth/Models/EndOfBookWording.swift -->

Skip finished, which a folder or a feed keeps for itself (Skip finished books in a folder, Skip finished episodes in a feed), applies whichever setting decides, and is checked unless it was cleared there; a book read from the reading list follows its list's own Skip finished books instead.
Continue to Next Book, and a choice to play the book below or above, pass over the books that rest at their end, finished, and go on with the first beyond them that is not.
With Skip finished cleared, they go on with the very next book, and a finished book they go on to plays from its beginning, after "Starting: TITLE" as for any book.
When only finished books lie that way, the book says so, as in "Finished: Dune.
Every book after it in the folder is finished.", or, going up, "Finished: Dune.
Every book before it in the folder is finished."; and with none that way, "Finished: Dune.
No more books in folder."
A feed's episodes and articles say the same words.

## The next episode of a feed
<!-- id: reader-next-episode-feed; keys: podcast, article, next episode download, newest first, download cancelled, Downloading the next episode; src: TextMouth/ViewModels/ReaderViewModel+EpisodeDownload.swift, TextMouth/ViewModels/ReaderViewModel+Predownload.swift, TextMouth/Models/EndOfBookWording.swift -->

For a feed's episode or article, the next one is the next one its feed lists that way, newest first, downloaded or not (see Listening on to the next episode, in [Podcasts and article feeds](feed-listening-and-settings.md)).
One that is not on this Mac is downloaded first, and that download goes first in the queue.
VoiceOver says "Finished: Episode 368.
Downloading the next episode: Episode 367."
("the next article" for an article), and "Starting: Episode 367" when the file arrives.
Until it arrives, the episode rests finished at its end, as a book that stops does (see [A book that rests finished at its end](reader-media-and-sleep-timer.md#a-book-that-rests-finished-at-its-end)).
If the download fails, VoiceOver says "The next episode could not be downloaded, so playback stopped." followed by the download's own sentence, as the episode's row says it; if TextMouth will not start the download, as while it quits, that sentence is "TextMouth is not downloading right now."
If you close the window before the file arrives, nothing starts when it does, and a sleep timer the window owns stops, as closing the window a timer belongs to stops it.
Nothing starts either, and nothing is said of the download, if you have moved on in another way: played the episode again, or taken the media controls for another book, by playing it or by bringing its window to the front.
Pressing Play on the finished episode ends the wait too, since Play does what the end does under the options in force then, which may be to wait again.
A sleep timer running in the window while it waits, one you start then included, goes on with the episode when it arrives and stops it when it runs out (see The sleep timer when listening goes on, below).
If the timer ran out meanwhile, or began to fade out, the episode does not start when it arrives, and what the timer said as it ran out is all that is said.
If you cancel that download yourself, with Cancel Download on its row, the Cancel of the Feed Downloads section, or Delete Feed…, VoiceOver says "Download cancelled, so playback stopped." and the episode stays finished; Play on it, which does what its end did, asks for the download again.

## The sleep timer at a book's end
<!-- id: reader-sleep-timer-at-book-end; keys: Next book not started, timer expired, fading out, timer ends listening; src: TextMouth/Models/EndOfBookWording.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

This window's sleep timer keeps the next book from starting, and starts no download for it either, when it ends listening at this book's end: when it is fading out, or is set for the end of the heading or of the book, which this end reaches.
VoiceOver says "Finished: Dune.
Next book not started because of the sleep timer."
(see [The sleep timer](reader-media-and-sleep-timer.md#the-sleep-timer)).
A timer counting minutes does not: it goes on with the next book (see The sleep timer when listening goes on, below).

## Where the next book opens
<!-- id: reader-where-next-book-opens; keys: NextBookWindow, This Window, A New Window, same window, new window, next book window; src: TextMouth/Models/NextBookWindow.swift, TextMouth/ViewModels/ReaderViewModel+NextBookWindow.swift, TextMouth/Views/NextBookWindowPicker.swift -->

Where the next book opens, whenever listening goes on from one book to another, is the Playback tab's "Open the next book in" (see [Settings](settings.md)).
For a feed or a plain folder, it is that feed's or folder's own choice in Feed Info and Folder Settings (see [Podcasts and article feeds](feed-listening-and-settings.md) and [The Library window](library-window.md)):

- This Window, the default, shows the next book in this window in place of the book here.
  No new window opens, and the window, which keeps its place and size on the screen, becomes the next book's.
  The book you leave is saved as closing its window saves it.
- A New Window opens a window for the next book and leaves this one, as TextMouth did before 0.2.5.
- The moves that follow it are the end of a book going on (Continue to Next Book, and a feed's, a folder's, or the reading list's choice to play the book below or above), Next in Reading List and Previous in Reading List, and Next in Folder and Previous in Folder (below).
  Opening a book from the Library window still opens its own window.
- A move through the reading list follows the global setting, since the reading list has no choice of its own.
  A move through a feed or a plain folder follows that feed's or folder's own choice when it has made one and its books go on to another book when one ends, and the global setting otherwise.
  The choice is read as the next book is asked for, so one changed meanwhile counts.
- A book already open in another window comes forward with that window, and, with This Window, this window closes, so no two windows show one book.
  With A New Window, this window stays open.
- With This Window, a new window opens all the same when switching this window could lose something:
  - this window has closed, as when you press Command-W just after VoiceOver says "Starting: TITLE", or is no longer on screen (a window that is minimized, or hidden along with TextMouth by Command-H, still counts as on screen);
  - a sheet or an alert is open over it (Edit Book Information, Search in Book, the headings, the bookmarks, the sleep timer, the voice, Export, or an error);
  - a text field of the window is being typed in (Go to Percent, Go to Time, or Go to Page);
  - this book's text is being edited in another app with Edit Text;
  - or the library is moving or not available.

  The next book then opens as with A New Window, and a book already open in another window comes forward as above, with this window left open.

## The sleep timer when listening goes on
<!-- id: reader-sleep-timer-when-listening-goes; keys: timer hand over, Opening, Starting, timer carried over, SleepTimerHandOver, moved to another book; src: TextMouth/ViewModels/ReaderViewModel+SleepTimerHandOver.swift, TextMouth/Models/SleepTimerHandOverWording.swift, TextMouth/Services/SleepTimerRegistry.swift -->

The sleep timer when listening goes on: a running sleep timer goes on with listening to the next book, in this window or in a new one, and stops that book when it runs out.
It keeps its kind, counting minutes, or waiting for the end of a heading or of a book, which then waits in the next book for the end of the heading being read there, or of that book, and its countdown is never started again.
It goes on at a book's end, with Next in Reading List and Previous in Reading List, and with Next in Folder and Previous in Folder:

- The timer waits for the next book however long that book takes to open, a download from iCloud included, and closing the old window meanwhile does not stop it.
  A countdown that the old book's pause halted stays halted until the next book plays.
  As a last resort, when no window has opened the next book 20 minutes after the move, TextMouth stops the timer and says what it says when the next book could not be opened (below).
- An episode that must be downloaded first is different.
  While it downloads, after "Downloading the next episode: TITLE" at a book's end, or Next in Folder's or Previous in Folder's "Downloading the next episode: TITLE" or "Downloading the previous episode: TITLE", the timer stays the old window's own.
  And it goes on with the move once the episode arrives.
  So closing the old window during that download ends the wait, and the episode does not start; it also stops the timer, as closing the window a timer belongs to does.
- A move that only opens its book, with "Opening: TITLE", takes the timer with it too.
  So with A New Window, or a new window opened because this one was busy, playing the old window's book afterwards plays it without the timer: the timer is the next book's, and it can pause only that book.
  Until the new window's book has loaded the timer is still the old window's, and its sheet shows and cancels it; once the book has loaded the timer is the new window's, and the old window shows none.
- A timer you set in the new window while its book loads replaces the one on its way from the old window, and Cancel Timer there ends it: the timer you choose in the window you are in is the one that counts.
- A timer set for the end of the heading or of the book that runs out at a book's end still ends listening there.
  A timer set for either after a book has ended, for example while the next episode downloads, goes on with the next book like any running timer, and stops at that book's end.
- A timer that runs out, or begins to fade out, before the next book starts has ended listening: the fade runs out, VoiceOver says "Sleep timer expired.
  Playback paused.", and the next book does not start, even if you close the old window or press Pause during the fade.
  Only Restart Sleep Timer changes that, as below.
- When the next book cannot be opened, the timer is cancelled, and VoiceOver says "Sleep timer cancelled, because the next book could not be opened."
  For a book that failed to load, a book whose opening from iCloud stopped or failed, and a book deleted meanwhile, it says so after the reason the book did not open, three seconds after the failure, so that the reason is read first.
  When the Library refuses to open the book, as it does while the library moves or is not available, it says so at once.
- Closing the next book's window while it is still loading cancels the timer without a word, as closing the window a timer belongs to does.
- Restart Sleep Timer, from its shortcut or the AirPods gesture, while the timer is on its way to the next book, starts a timer counting minutes again at its full duration, and it still goes on with the move.
  That holds for one that had begun to fade out too, whose fade ends.
  A timer waiting for the end of a heading or of a book keeps waiting.
  The book you left does not resume, the next book plays as its move said, and VoiceOver says "Timer reset."
- Next or Previous pressed while the timer fades out ends the fade and the timer, as Pause does, and the book moved to starts.
  VoiceOver says "Sleep timer cancelled, because you moved to another book while it faded out." after "Starting: TITLE", or after "Opening: TITLE", or after "Downloading …" for an episode that Next in Folder or Previous in Folder downloads first.
- A second move made before the first move's book has started replaces the first: a second Next or Previous, a command pressed just after a book's end has said "Starting: TITLE", and, with A New Window, a press in the old window while the first book still loads.
  The first book does not start; with A New Window its window stays open, showing it.
  The timer goes on to the book you end up at, and that book plays when the first move was to play its book.
  A fade under way ends as the item above says.

## A one-file audiobook's last chapter
<!-- id: reader-one-file-audiobook-last-chapter; keys: m4b, chapter markers, finished early, last chapter, tenth of a second; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Models/EndOfBookRule.swift -->

A one-file audiobook with chapter markers plays its last chapter to its file's end before it is announced finished.

## A finished book
<!-- id: reader-finished-book; keys: Finished, Starting again, Play on a finished book, 100 percent, end position, Go to Percent; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Models/EndOfBookWording.swift, TextMouth/Models/EndOfBookRule.swift -->

Unless it loops, a book that plays or is read to its end is saved exactly at its end, its last chapter at its full length, and stays finished after its window closes or TextMouth quits.
A finished book whose last chapter has grown shorter since, as when its text is read anew or edited, opens at its new end, still finished, as its row says; a place saved past the end of any other chapter opens at that chapter's end.
A finished book's library row says "Finished" in place of its percent and time left, as in "Dune, by Frank Herbert, Finished, EPUB", and so do Speak Info, Where Am I?, and Copy Reading Position, while the reader's own status row keeps its percent and time.
Play on a finished book does what its end did, without playing the end again:

- with Stop it says "Finished: Dune" and plays nothing;
- with Stop, and Play Starts Over, which stops at the end as Stop does, it starts the book over from its beginning, saying "Starting again: Dune";
- with Continue to Next Book it goes on to the next book not finished (the very next book where Skip finished is cleared), or says why none follows, as the end did;
- with Loop to Start it plays the book again;
- a book with no choice of its own whose feed or folder has one does what that choice says (above);
- and a book read from the reading list does what the list's own When a book ends says (below).

A caption under the Playback tab's picker says what Play does with the first two.
A backward skip after the end replays the end (see [A book that rests finished at its end](reader-media-and-sleep-timer.md#a-book-that-rests-finished-at-its-end)), which counts as no new finish, and a forward skip at the end stays there.
Go to Percent with 100 lands just short of the end, so Play then plays the last moment and ends the book again.

## The Reading List
<!-- id: reader-windows-reading-list; keys: Next in Reading List, Previous in Reading List, Remove books when finished, ReadingListReaderWording, read from the list; src: TextMouth/ViewModels/ReaderViewModel+ReadingList.swift, TextMouth/Models/ReadingListReaderWording.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift -->

A book you open from the Reading List, by its row, its Open item, or Return, is read from the list.
Its window is titled "Reading List: Moby-Dick by Herman Melville" in place of "Book: Moby-Dick by Herman Melville", the line under its title says where it stands, as in "Reading list, book 3 of 12", and the full Where Am I? adds the same words.
When it ends, the list's When a book ends decides what follows, in place of the book's own end-of-book setting:

- the book below it, or above it, as the option says, opens and plays, read from the list too, passing over finished books while Skip finished books is checked, as in "Starting: Dune";
- or the book stops, and VoiceOver says why, as in "Finished: Moby-Dick.
  End of the reading list.", "Finished: Moby-Dick.
  The reading list is set to stop when a book ends.", or "Finished: Moby-Dick.
  Every book below it in the reading list is finished."

Either way the book counts as finished.
A sleep timer running in that window goes on with the next book, as it does in a folder (see The sleep timer when listening goes on, above).
Navigate menu, Next in Reading List and Previous in Reading List open the book below or above, passing over finished books the same way, and play it when this book was playing, as in "Starting: Dune"; from a book that wasn't playing, they open the next without playing it, as in "Opening: Dune".
Where the next book opens, in this window or a new one, at the end of a book and with these commands alike, follows the global Open the next book in (see Where the next book opens, above), and a sleep timer running in the window goes with the move.
With no book that way they say so, as in "No next book in the reading list."
They are dimmed for a book not read from the list, and have no keys until you give them some in the Shortcuts tab of Settings, under Navigation.
A book opened any other way, from another category, Continue Listening, or Finder, reads as before, even when it is in the list.
A book taken off the list while it is open, or removed from the library, goes back to its own end-of-book setting, and putting it back on the list doesn't change that until you open it from the Reading List again.
With the list's Remove books when finished checked, a book that ends and goes on to the next book leaves the list once its window has gone on to that book, so the next book still opens as above.
A book that ends at Stop, or at the end of the list, stays on the list while its window rests on it, and the window still follows the list for a rewind, Play at the end, and Next in Reading List; it leaves the list when that window opens another book or closes, and then reads as any book.

## Next in Folder and Previous in Folder
<!-- id: reader-next-folder-previous-folder; keys: Next in Folder, Previous in Folder, folder navigation, Navigation shortcuts, next item of a feed; src: TextMouth/ViewModels/ReaderViewModel+FolderNavigation.swift, TextMouth/Models/FolderNavigationWording.swift, TextMouth/Models/FolderNavigationHistory.swift -->

Navigate menu, Next in Folder and Previous in Folder go to the next or the previous item of this book's folder or feed, in any reader window, however the book was opened.
They have no keys until you give them some in the Shortcuts tab of Settings, under Navigation, and the Navigate menu offers them in a reader window alone.

- Which item: Next goes the way the end of the book would go on, so up in a feed or a folder whose When a book ends plays the one above, and down in every other case, when the end would stop included; Previous goes the other way.
  The item is the one the end of a book would go on to that way: the next book in the folder's order as its list shows it, or, for a feed, the next item of its list, newest first, with an item you moved into the library passed over.
  Finished items are passed over, unless Skip finished is cleared in the feed's or folder's settings, as at a book's end (above).
- A book that was playing pauses where it is, and the item plays, after VoiceOver says "Starting: TITLE".
  From a book that wasn't playing, the item only opens, as in "Opening: TITLE".
  Where it opens, in this window or a new one, follows the feed's or folder's own Open the next book in, or the global one (see Where the next book opens, above), and a sleep timer running in the window goes with the move (see The sleep timer when listening goes on, above).
  A second press within half a second of the first goes to the same item, since the window has not switched yet; a press after that goes one further.
- With no item that way, the book is left as it is, playing or not, and VoiceOver says why, as a book's end says it, with a full stop: "No more books in folder.", "Every book after it in the folder is finished.", or, when the way is up, "Every book before it in the folder is finished."
- An episode or article of a feed that is not on this Mac is downloaded first, as at a book's end (above), and goes on when it arrives.
  VoiceOver says "Downloading the next episode: TITLE" for Next in Folder, or "Downloading the previous episode: TITLE" for Previous in Folder ("article" for an article), whichever way the feed plays, and then "Starting: TITLE" or "Opening: TITLE" when the file arrives.
  - If the download fails, VoiceOver says "The next episode could not be downloaded." for Next in Folder, or "The previous episode could not be downloaded." for Previous in Folder, each followed by the download's own sentence giving the reason, and "article" for an article.
    When the book was playing, ", so playback stopped" comes before the full stop, as in "The next episode could not be downloaded, so playback stopped." followed by the reason.
  - If you cancel the download, VoiceOver says "Download of the next episode cancelled." for Next in Folder, or "Download of the previous episode cancelled." for Previous in Folder.
    When the book was playing, ", so playback stopped" comes before the full stop, as in "Download of the next episode cancelled, so playback stopped."
  - A later move ends the wait for the episode: it goes on downloading, but does not start when it arrives.
    Closing the window does the same.

## Quitting TextMouth
<!-- id: reader-quitting-textmouth; keys: Command-Q, log out, shut down, save place on quit, 30 seconds; src: TextMouth/App/QuitFinisher.swift, TextMouth/ViewModels/ReaderViewModel+SavedPlaces.swift, TextMouth/ViewModels/LiveReadingPositions.swift -->

Quitting TextMouth, by Command-Q, logging out, or shutting down, saves the place of each open reader whose place moved since its last save, so a book that was playing opens at the second it stopped, not up to 30 seconds back.
A reader at rest writes nothing, so a Mac that sits idle beside another on a shared library never undoes the other's newer places.

## Words kept around your places
<!-- id: reader-words-kept-around-your-places; keys: text anchors, place snapshots, reading position, bookmark words, skipped heading; src: TextMouth/ViewModels/LibraryViewModel+TextAnchors.swift, TextMouth/ViewModels/LibraryViewModel+PlaceSnapshots.swift -->

TextMouth keeps the words around each place it saves for you (your reading position, each bookmark, and each heading you skip), so they can be found again when a book's text is read anew.
Places saved before this version take their words from each book as it reads now: when the book next opens, and for the others once at launch, before any text is rebuilt.
Nothing is spoken or shown; an audiobook's places count time and need none.

## Places follow their words
<!-- id: reader-places-follow-their-words; keys: Redo Text Extraction, Replace Existing, re-read, text changed, bookmarks move, skipped sections; src: TextMouth/ViewModels/LibraryViewModel+TextAnchors.swift, TextMouth/ViewModels/LibraryViewModel+PlaceSnapshots.swift, TextMouth/ViewModels/ReaderViewModel+SavedPlaces.swift -->

Your places follow their words when a book's text changes.
When TextMouth reads a book's text again, after an update changes how it reads books, your reading position, bookmarks, and skipped sections stay with their words.
An update that gives books pages makes it read them again at the next launch (see [Where TextMouth keeps your library](book-packages.md)).
They stay with their words after Redo Text Extraction too.
When a book's text changes in any other way, they still do: each time you open a book, TextMouth checks every saved place, and finds one whose words have moved.
When you edit a book's text with Edit Text, your places follow each edit too, and an open reader's cursor stays on the words it was at.
When Replace Existing puts a new copy in a text book's place, your reading position, bookmarks, and skipped sections follow their words into it as well (see [Adding books](duplicate-books.md)).
All of this is silent.
A skipped section the new text no longer has is kept aside and skips nothing, until a later text brings it back.
A place whose words can't be found anywhere stays where it was saved, with its words, so a later version of the text that has them again can still find it.
