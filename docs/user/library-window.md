# The Library window
<!-- id: library-window; keys: Library view, library list, book list, folders; src: TextMouth/Views/Library/LibraryView.swift, TextMouth/ViewModels/LibraryViewModel.swift -->

Part of [TextMouth's documentation](../../README.md).

## Choosing a view
<!-- id: choosing-view; keys: View pop-up, Library view, view picker, categories, categoryPickerLabel; src: TextMouth/Models/LibraryViewPickerWording.swift, TextMouth/ViewModels/LibraryViewModel+Views.swift, TextMouth/Views/Library/LibraryView.swift -->

Choose what the window lists in the View pop-up, a pop-up button above the list.
Its visible label is "View", and VoiceOver calls it "Library view", reading its value first, as in "Unopened, Library view, pop-up button"; a braille display shows the value and the label.
Choosing an item says nothing more than VoiceOver's own reading of the item.
The pop-up is no wider than 320 points, so a long name never makes the window's content wider than the window.
TextMouth ships six views: Folders, All Items, Unopened, Recently Opened, Reading List, and Feeds; you arrange them, hide them, and make views of your own in the Library tab of Settings (see [Settings](settings-library.md)).

### Which views the pop-up offers
<!-- id: which-views-pop-up-offers; keys: Always, When Applicable, hidden view, Library tab, view order; src: TextMouth/Models/LibraryViewDefinition.swift, TextMouth/Models/LibraryViewDefinitionList.swift, TextMouth/ViewModels/LibraryViewModel+Views.swift, TextMouth/Models/LibraryViewsSettingsWording.swift -->

Which views the pop-up offers: the views set to Always; those set to When Applicable, while they list something; and the view the window shows, whatever its setting.
They come in the order of the Library tab's list.
Folders is always offered.
The Reading List lists something while it holds a book, an episode, or an article.
Any other view lists something while it finds at least one row, a book or a feed; Feeds, as shipped, lists something while there is a feed, subscribed or not.
TextMouth ships Folders, All Items, Unopened, Recently Opened, and the Reading List set to Always, and Feeds set to When Applicable, last in the list.

### A window keeps its view
<!-- id: window-keeps-view; keys: view deleted, hidden view, shownViewID, per-window view, new window; src: TextMouth/ViewModels/LibraryViewModel+Views.swift, TextMouth/Models/LibraryViewPickerWording.swift, TextMouth/Views/Library/LibraryView.swift -->

A window keeps its view until you choose another.
A view you hide in Settings, or that stops listing anything, while a window shows it, stays shown in that window, and in its pop-up, until you choose another view, and then leaves the pop-up; nothing moves under VoiceOver's cursor, and nothing is said.
A view deleted while a window shows it cannot stay: the window shows the first view its pop-up offers instead, and says, as in "The view this window showed was deleted.
It now shows Folders."
A new Library window opens at the first view its pop-up offers, which is Folders until you move another view above it.

### The Folders view
<!-- id: folders-view; keys: breadcrumbs, folder navigation, Up One Level, Feeds section, feed folder; src: TextMouth/Views/Library/LibraryView.swift, TextMouth/Models/FolderNavigationWording.swift, TextMouth/Views/Feeds/LibraryFeedFolders.swift -->

Folders shows one folder at a time, with the folders' breadcrumbs, the Folders section, and the commands of folders; the rest of this page says what is in a folder.
Every other view lists books from every folder.
Where there are feeds, a Feeds section follows the folders in Folders (see [Podcasts and article feeds](feeds.md)).
A feed's downloaded episodes and articles are listed in its feed's folder, where the feed's row stands for them in Folders and in a view that lists feeds.
Of the shipped views, only Recently Opened lists them, and the Reading List holds the ones you add to it; a view of your own lists them when it is set to list Episodes or Articles.

### What the shipped views list
<!-- id: what-shipped-views-list; keys: built-in views, default views, view definition, one episode per feed; src: TextMouth/Models/LibraryViewDefinition.swift, TextMouth/Models/LibraryViewFilterEvaluator.swift, TextMouth/Models/LibraryViewDefinitionStore.swift -->

All Items, as shipped, lists every book and every feed, sorted by title until you choose another sort.
Unopened, as shipped, lists every book you have never opened, from every folder, and a book leaves it once you open it, and a feed only while it has a new episode or article among those it lists, one published, or, undated, first seen, since you subscribed and neither played nor opened.
So a podcast's back catalog never keeps it there.
It replaces No Folder: the books in no folder, which No Folder listed, are at the top of the library in Folders.
Recently Opened, as shipped, lists the ten books, episodes, and articles you opened last, and of each feed's episodes and articles only the one you opened last, which takes one of the ten places; it keeps the sort you chose for it under its old name, Recent.
The Reading List lists the books you add to it, in the order you arrange (below).

### The Feeds view
<!-- id: choosing-feeds-view; keys: feed list, Sort feeds by Title, feedsSortMenuLabel, subscribed feeds; src: TextMouth/Models/LibraryViewPickerWording.swift, TextMouth/ViewModels/LibraryViewModel+Views.swift -->

Feeds, the sixth view, lists the feeds alone, each by title, as the Feeds section lists them.
It has no Books section, so no "Books (0)" appears.
The window's title is "Library: Feeds", with no sort in it.
Its Sort button, which VoiceOver calls "Sort feeds by Title", has one item, "Title", checked, with the hint "Feeds are always listed by title"; choosing it says "Feeds are listed by title".
Opening a feed's row there opens the feed's folder, in Folders, as it does in the Feeds section.

### Views of your own
<!-- id: views-your-own; keys: custom view, view editor, filter view, conditions, smart view; src: TextMouth/Models/LibraryViewFilterEvaluator.swift, TextMouth/Models/LibraryViewDefinition.swift, TextMouth/ViewModels/LibraryViewEditorModel.swift, TextMouth/Models/LibraryViewPickerWording.swift -->

A view of your own, or a built-in view you changed, lists what its conditions find.
Its window title is "Library: Unread EPUBs (Date Added Descending)", the view's name and the sort shown; a view that lists only feeds is named alone, as Feeds is.
A view without a Books section that lists nothing, such as Feeds, a view of your own, or a built-in view you changed to list feeds alone, shows one row, "Nothing matches this view now."
The summary bar and Speak Info count the rows the view lists, as in "23 books, 2 feeds" or "5 episodes".
The shipped views look as they always have, and a shipped view with nothing to list shows no such row.

### Go to View
<!-- id: go-view; keys: Command-1, Go to View 1, goToView, Library menu, number keys; src: TextMouth/Models/KeyboardShortcut.swift, TextMouth/Models/LibraryViewPickerWording.swift, TextMouth/ViewModels/LibraryViewModel+Views.swift, TextMouth/App/MenuCommands.swift -->

Go to View goes to a view by number.
Command-1 to Command-9, the Shortcuts tab's actions "Go to View 1" to "Go to View 9" under Library, work in a Library window.
They go to the first to the ninth view its pop-up offers a window showing no view of its own.
They count the views set to Always and those set to When Applicable that list something, and never one a pop-up keeps only because its window shows it, so a key always goes to the same view.
The Library menu's Go to View submenu lists those views by name, the first nine with their keys; with no Library window in front it has one dimmed item, "No Library Window".
Going to a view says its name and what it lists, as in "All Items, 743 books, 2 feeds", or, for a view of your own or a built-in filter view that lists nothing, "New Episodes, nothing matches this view now."; a key with no view says "There is no view 7.
Go to View reaches 6 views."

## Sorting
<!-- id: sorting; keys: Sort menu, sort order, ascending, descending, title sort, manual order, LibrarySortState; src: TextMouth/Models/LibrarySortState.swift, TextMouth/Models/LibraryBookSorter.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift -->

Sort by title, author, date added, last opened, file size, or your own manual order.
Each folder and each view remembers its own sort, except the Reading List, and a view that lists only feeds, which always lists them by title, which always shows the order you give it (below).
Until you choose a sort in Unopened, it uses the sort you chose for No Folder, unless that was manual order, and otherwise sorts by date added, newest first.
In the Sort menu a checkmark marks the field shown; choosing that field again keeps the sort as it is, and VoiceOver says the sort shown, as in "Sorted by Title, ascending".
The item below the fields, Sort Descending or Sort Ascending, reverses the order; it is dimmed in manual order, which has no direction.
Whether a title's leading article counts when the Title sort orders books, and when a tie is broken by title, is the Leading articles setting's choice, in the Library tab of Settings (see [Settings](settings-library.md)); as shipped it counts, and The Hobbit sorts among the T's.

## Where a book's author comes from
<!-- id: where-book-author-comes-from; keys: creator, Unknown author, EPUB metadata, contributor, Book Info; src: TextMouth/Parsers/EPUBParser.swift, TextMouth/Services/FileImportService.swift, TextMouth/Models/BookInfo.swift -->

A book's author comes from its file.
An EPUB names its author in a creator element, or, in files some converters write, only in a dcterms:creator meta element or in a contributor marked as the author.
TextMouth reads them all, preferring a creator marked as the author to one listed before it, such as an illustrator, and reading a creator that says only Unknown as naming no one.
A book whose file names no one is listed under Unknown, and Book Info, or an EPUB's metadata editor, lets you type an author in, which is kept whatever the file says.

## Moving books in manual order
<!-- id: moving-books-manual-order; keys: reorder, drag to reorder, Move Book Up, Move Book Down, manual sort; src: TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift, TextMouth/Models/LibrarySortState.swift, TextMouth/App/MenuCommands.swift -->

In manual order, Move Book Up and Move Book Down (Library menu, Shift-Command-Up Arrow and Shift-Command-Down Arrow), or dragging, rearrange a folder in Folders, the top of the library included, and at the Reading List they rearrange the list.
All Items, Unopened, and Recently Opened mix books from many folders, which share no one order, so nothing rearranges them there.
Move Book Up and Move Book Down say why when they can't move a book, and are dimmed in any window but a Library window.
In a folder in Folders that is not in manual order they say "Books can be moved only in a folder sorted by Manual Order, and this folder is not.
Choose Manual Order in the Sort menu, then try again."
In any other view, a view of your own and Feeds included, they say "Books can't be moved in this view.
Go to a folder in Folders, or to the Reading List, then try again."
With no book selected they say "No book is selected.
Select the book to move, then try again.", and with several "A move shifts one book at a time, and several are selected.
Select one book, then try again."
A feed's episode or article in a folder can't be moved, and they say "TITLE is an item of a feed, and a feed's items can't be moved."; at the Reading List it moves like any book.

## Move Up and Move Down on a row
<!-- id: move-up-move-down-row; keys: row actions, Actions menu, accessibility action, LibraryManualMove; src: TextMouth/Views/Library/LibrarySubviews.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift -->

Where the list shows an order you arrange, a folder in manual order or the Reading List, a book's row also offers Move Up and Move Down in its context menu and as the first of its actions in VoiceOver's Actions menu (VO-Command-Space), each only where the book can make that move.
The first book offers Move Down alone, and a book alone in the list offers neither.
The VoiceOver actions move the book one place and say where it now stands, as in "Dune, 3 of 12"; the context menu's items, and Move Book Up and Move Book Down from the Library menu or the keyboard, say which book the move passed, as in "Moved Dune above Almanac".
Should the list change after the row offered a move it can no longer make, the action says so, as in "Dune can't move up."

## The Reading List
<!-- id: library-window-reading-list; keys: reading list, playlist, queue, ReadingList; src: TextMouth/Models/ReadingList.swift, TextMouth/Models/ReadingListWording.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift, TextMouth/Views/Library/ReadingListOptionsBar.swift -->

The Reading List lists books from any folder in an order you arrange, each book once.

### Adding and removing books
<!-- id: adding-removing-books; keys: Add to Reading List, Remove from Reading List, ReadingListCommand, reading list label; src: TextMouth/Models/ReadingListCommand.swift, TextMouth/Models/ReadingListWording.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift, TextMouth/Views/Library/LibrarySubviews.swift -->

Add to Reading List, in a book's context menu, its actions in VoiceOver's Actions menu, and the Library menu, adds the selected books to its end, and Remove from Reading List takes them off it, leaving them in the library.
For several books selected, each command counts them, as in "Add 3 Books to Reading List", and a selection holding books of both kinds offers both.
VoiceOver says what changed, as in "Added to reading list: Moby-Dick", or why nothing did, as in "Moby-Dick is already in the reading list."
Neither command has a key until you give it one in the Shortcuts tab of Settings, under Library.
In every other view, a book in the list says "In reading list" right after its title and author in its row's VoiceOver label, as in "Loose Pages, by Ines Okonkwo-Varga, In reading list, New, Plain Text", so it is in the same place on every row.
In edit mode a selected row still begins "Selected", and the row has no VoiceOver value of its own.

### Rearranging and removing at the Reading List
<!-- id: rearranging-removing-at-reading-list; keys: Reading List Order, empty list, Delete key, Remove from Library; src: TextMouth/Models/ReadingListWording.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift -->

At the Reading List, Move Book Up, Move Book Down, and dragging rearrange the list, its Sort menu names its one order, Reading List Order, and an empty list says how to add a book.
Remove from Library… and the Delete key still remove a book from the library there, so take a book off the list alone with Remove from Reading List.
A book that leaves the library leaves the list too, one taken out with Remove from Library Only included, even when the next launch is what takes it out.

### Importing at the Reading List
<!-- id: importing-at-reading-list; keys: import to reading list, duplicate, Replace, Library Root, ZIP; src: TextMouth/ViewModels/LibraryViewModel+ReadingList.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/Models/ReadingListWording.swift -->

At the Reading List, Open Book…, Import Folder…, and New from Text…, whether chosen in the Add to Library sheet or from their menus, put their books in the folder the window showed last, as anywhere else, and add them to the end of the reading list.
VoiceOver says where the books themselves went, as in "Added to reading list: Moby-Dick.
The book is in Essays/Sea.", calling the top of the library Library Root, as the folder pickers do, and says it after the import's own words, not over them.
A ZIP archive's books join together, a duplicate joins once you keep both, and a book opened from Finder never joins.
Replace on a duplicate gives the new copy the old one's place on the reading list, wherever you import it; at the Reading List, the new copy of a book that wasn't on the list joins its end, and VoiceOver says so.

### The options above the list
<!-- id: options-above-list; keys: options bar, When a book ends, Skip finished books, EndOfBookRule; src: TextMouth/Views/Library/ReadingListOptionsBar.swift, TextMouth/Models/ReadingListWording.swift, TextMouth/Models/EndOfBookRule.swift -->

Above the list, When a book ends chooses what a book opened from the list does at its end: Play the book below, the default, Play the book above, or Stop (see [Reader windows](reader-book-end.md)).
Skip finished books, checked unless you clear it, passes over the books Books Finished counts, in the Stats tab of Settings: a book joins them when it is played or read to its end and doesn't start again, and stays when you read it again.

### Remove books when finished
<!-- id: remove-books-when-finished; keys: removeFinishedLabel, finished books, auto remove, Books Finished; src: TextMouth/Models/ReadingListWording.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift, TextMouth/ViewModels/ReaderViewModel+ReadingList.swift -->

Remove books when finished, unchecked unless you check it (VoiceOver reads its hint, "Takes each finished book off the list when its window moves on or closes.
Books finished before you turn it on stay."), takes a book off the list as soon as it is finished, whether you opened it from the list or not, the same way Remove from Reading List does, so the book stays in the library and is saved off the list at once.
Nothing is said of it, so the end of a book says what it always said, and the Reading List, if open, shows the book gone.
A book read from the list that ends still goes on to the book that followed it, or preceded it with Play the book above, and Skip finished books still passes over finished books after it.
While its window rests on the finished book, the book stays on the list, so Rewind, Play, and Next in Reading List in that window still follow the list as before, and it leaves the list when the window goes on to another book or closes.
A book finished with no window resting on it leaves at once.
A feed episode you mark played, with Mark Played or Mark All Played, is finished in the same way: it leaves at once, or, while a window reads it from the list, when that window goes on or closes.
Mark Unplayed lets an episode still waiting to leave stay, and puts none back.
Checking it takes off none of the books already finished; only books finished from then on leave.
A rewind's replay of a book's end tells nothing, so a book that stayed on the list stays, and Books Finished counts a book only once.
A book that is not on the list is not touched.
The sleep timer, Where Am I?, and Next in Reading List are unchanged, though a book that has left the list reads as any book from then on (see [Reader windows](reader-book-end.md)).

### The options bar in a cloud library and a narrow window
<!-- id: options-bar-cloud-library-narrow; keys: Keep these books on this Mac, kept books, iCloud, narrow window; src: TextMouth/Views/Library/ReadingListOptionsBar.swift, TextMouth/Models/ReadingListWording.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift -->

In a library in the cloud the options bar has a fourth control, the checkbox "Keep these books on this Mac", checked unless you clear it, which keeps every book on the list downloaded on this Mac (see [Cloud libraries](cloud-library.md)).
It is this Mac's own choice, and it is not there for a library on this Mac or another drive.
In a window too narrow for all the options on one line, the bar goes on to a second line rather than cutting a label, in the same order.

## Edit Mode
<!-- id: edit-mode; keys: select several books, Select All, Deselect All, Exit edit mode, Command-E, toggleEditMode; src: TextMouth/Views/Library/LibrarySubviews.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Models/KeyboardShortcut.swift -->

Edit Mode selects several books at once to move or remove them, or to add them to the reading list or take them off it.
The bar above the list counts the books selected, in the list or with edit mode's checks, as in "Edit mode, 3 of 12 books selected", counting only books the list shows, and the toolbar's Done counts them the same way in its hint.
Select All becomes Deselect All once every book listed is selected, and is dimmed while no book is listed.
In edit mode, the bar above the list offers Add to Reading List and Remove from Reading List beside Move, for the books selected: Add for those not in the list, Remove for those in it, and both for a selection holding each.
VoiceOver hears how many books each acts on, as in "Add 3 books to the reading list", and each says what it did, as the context menu's commands do.
With nothing selected, the bar shows the one the view suggests, dimmed: Remove from Reading List at the Reading List, and Add to Reading List elsewhere.
At the Reading List, books you take off the list leave the selection too.
Leave edit mode with the toolbar's Done, which VoiceOver calls Exit edit mode, or Edit Mode in the Library menu, Command-E; the bar has no Done of its own.

## What a row's hint says
<!-- id: what-row-hint-says; keys: accessibilityHint, row hint, VoiceOver hint; src: TextMouth/Views/Library/LibrarySubviews.swift -->

A row's hint says what it does, never a gesture or a key, since VoiceOver, a braille display, and the keyboard each do it their own way: a folder's row says "Opens the folder.", and a book's "Opens the book.", or, in edit mode, "Selects this book." or "Deselects this book."

## The Move dialog
<!-- id: library-window-move-dialog; keys: Move to Folder, Destination folder, New Folder, Shift-Command-M, move books; src: TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/App/MenuCommands.swift -->

The Move dialog puts the selected books in a folder chosen from its pop-up, or in one its New Folder fields make.
New Folder… opens those fields with the keyboard in their name field, where VoiceOver lands.
While they are shown, Return presses their Create, and Escape, like Cancel New Folder, closes them, keeps the folder chosen, and says so, as in "New Folder cancelled.
Destination folder: Reports."; Create makes the folder and says so, with the new folder chosen, as in "Folder Q3 created.
Destination folder: Reports/Q3."; once they close, Return presses Move again and Escape closes the dialog.

### Episodes and articles
<!-- id: episodes-articles; keys: feed items, Move to Library, feed folder, stay in feeds; src: TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/LibraryViewModel+MoveToLibrary.swift, TextMouth/ViewModels/LibraryViewModel+FeedItemMove.swift -->

Episodes and articles stay in their feeds' folders: their rows offer no Move to Folder… (Move to Library…, on a downloaded one's row, makes it a book of the library's own; see [Podcasts and article feeds](feed-commands.md)).
With only episodes and articles selected, the Library menu's Move to Folder… (Shift-Command-M) and the edit bar's Move open no Move dialog, while a selection holding books too moves only its books.
Either way VoiceOver says which stayed, a moment after the dialog has closed when there is one, as in "Left “Ep.
368” where it is: episodes and articles stay in their feeds; Move to Library… makes one a book of your library."

### When a move fails
<!-- id: when-move-fails; keys: move failed, sheet stays open, Delete Folder, Move Contents, rename; src: TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift, TextMouth/Models/FolderOperationConflict.swift -->

A move, a folder's rename or move, or Delete Folder's Move Contents that fails keeps its sheet open with the reason, which VoiceOver hears once, and trying again clears that reason until the new attempt answers.

## Book Info and Command-I
<!-- id: book-info-command-i; keys: Info sheet, title and author, metadata editor, showBookInfo; src: TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Views/Library/LibraryBookInfoLoader.swift, TextMouth/Models/KeyboardShortcut.swift -->

Book Info, in a book's context menu, edits a plain text, Markdown, or HTML book's title and author (an EPUB's or an audiobook's metadata opens in an editor of its own, and an episode's or article's in its feed opens read-only; see [Podcasts and article feeds](feed-commands.md)).
Save waits for a title of more than spaces, and drops the spaces typed around the title or the author.

### The Braille Code row
<!-- id: braille-code-row; keys: braille table, braille language, bookInfoLabel, mac: table name; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Models/BrailleTableCatalog.swift -->

A braille book's sheet, under the heading Book Information, has the same fields and one more row, "Braille Code", after Format, which names the code the book was imported with, such as "Unified English Braille, contracted (Grade 2)".
VoiceOver reads it as "Braille Code, Unified English Braille, contracted (Grade 2)".
A book read with one of this Mac's tables (see [Settings](settings.md)) has its language after the code, as in "French braille, contracted (Grade 2), in French", or, for a table that states no contraction, "Italian braille, in Italian"; Speak Full Info says the same words after "Braille code: ".
A book an iPhone read with a table of that kind, whose stored name has no "mac:" in front, is named the same way.
When this Mac no longer has the table, the row gives the table's stored name instead, as in "mac:fr-bfu-g2.ctb".
A book read with a table that only writes braille (see Tables that only write braille, in [Settings](settings-braille.md)) is named the same way and keeps working.

### The Text Encoding row
<!-- id: text-encoding-row; keys: character encoding, charset, bookInfoLabel; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/ViewModels/TextEncodingChoiceModel.swift -->

A plain text, Markdown, or HTML book you added from a file has one more row in its Book Information sheet, "Text Encoding", after Format.
It is a pop-up button that names the encoding the book's file is read in and reads the file again in another when you choose one (see Text Encoding, in [Book Information](book-information.md#text-encoding)).

### Command-I
<!-- id: command-i; keys: Info shortcut, Feed Info, folder summary, showBookInfo; src: TextMouth/Models/KeyboardShortcut.swift, TextMouth/App/MenuCommands.swift, TextMouth/ViewModels/LibraryInfoSpeaker.swift -->

Command-I opens Book Info for the selected book and Feed Info for a feed's row, and, for a folder, which has no Info sheet, speaks the folder's full summary, as Speak Full Info does (see [Letter keys and Speak Info](library-typing-and-speak-info.md#speak-full-info)).
With several rows selected it acts on the first in the list's order, in Edit Mode on the first book selected, and with none it does nothing.

## Commands in a book's context menu
<!-- id: commands-book-context-menu; keys: right-click menu, Actions menu, Download Now, Remove Download, Edit Text With, Transcribe Audio, Edit Audio; src: TextMouth/Views/Library/LibrarySubviews.swift, TextMouth/Models/LibraryCloudWording.swift, TextMouth/Models/LibraryAudioCommand.swift, TextMouth/Models/BookTextEditWording.swift -->

A book's context menu, and its actions in VoiceOver's Actions menu (VO-Command-Space), include Show in Finder, which selects the book's package in Finder.
In a library in the cloud they also offer Download Now, Remove Download, and Keep on This Mac (see [Keeping your library in the cloud](cloud-library.md)).
An audiobook's also offer Edit Audio… (see [Editing audio](editing-audio.md)) and Transcribe Audio…, which reads Retranscribe Audio… once the book has a transcript.
A transcribed audiobook's also offer Clean Up Transcript (Experimental)… and Delete Transcript… (see [Transcribing an audiobook](transcribing.md)).
A feed's episode, whose audio can't be edited, offers no Edit Audio….

## Exporting from the Library window
<!-- id: exporting-from-library-window; keys: File menu, export selected books, noBooksSelected, nothing to export; src: TextMouth/Models/BookExportWording.swift, TextMouth/ViewModels/BookExportModel.swift, TextMouth/App/MenuCommands.swift -->

File menu, Export… exports the books selected in the Library window, and a book's context menu (VO-Shift-M) has Export… too, or Export 3 Books… for a selection of three (see [Exporting books](exporting-books.md)); with no book selected, VoiceOver says "No books are selected."
With neither a Library window nor a book's window in front, as when only Settings is open, File menu, Export… says so instead: "No Library window or book is open, so there is nothing to export." or "Switch to a Library or book window, then choose Export again."
A text book's context menu, and a transcribed audiobook's, also has Edit Text in Default Editor and Edit Text With…, unless several books are selected or the book is a feed's article (see [Editing a book's text](editing-book-text.md)).
These commands aren't among the row's actions in VoiceOver's Actions menu.

## The summary line
<!-- id: summary-line; keys: summary bar, book count, time remaining, status line, CountWording; src: TextMouth/Models/CountWording.swift, TextMouth/Models/FolderNavigationHistory.swift, TextMouth/Views/Library/LibrarySubviews.swift, TextMouth/Views/Settings/StorageSettingsView.swift -->

A summary line gives each location's book count and its listening time remaining at the current speed, and, in a library in the cloud, how many of its books are in the cloud and how many are kept on this Mac.
The count never counts a feed's episodes and articles as books: where the Feeds section lists feeds, it names them beside the books, as in "743 books, 2 feeds", or "2 feeds" where there is no book.
In Recently Opened and the Reading List, which list episodes and articles beside books, it counts each kind, as in "9 books, 1 article", as the list's heading does, "Books (9), Articles (1)".
And in a feed's folder it counts the feed's episodes instead (see Feeds in the library, under [Podcasts and article feeds](feeds.md)).
VoiceOver hears the same words entering a folder, as in "Library, 743 books, 2 feeds", and in a folder's row, as in "Podcasts, 3 books, 2 feeds".
Storage settings' Library Statistics count the books, then the feeds, where there are any, the folders, and the books kept in packages, and Use This Library's confirmation counts the library in use the same way.

## The Continue button
<!-- id: continue-button; keys: Continue listening, last opened book, resume, time left; src: TextMouth/Views/Library/LibraryView.swift, TextMouth/Models/ReaderTimeWording.swift -->

The Continue button names the book last opened, as in "Continue: Emma", and opens it.
It shows that book's time left as a row does, as in "16:00 left", and VoiceOver says it as a row does, as in "Continue listening to Emma, 16 minutes remaining"; for a finished book, which has no time left, it shows and says none, as in "Continue listening to Emma".

## The toolbar's Add and Settings buttons
<!-- id: toolbar-add-settings-buttons; keys: plus button, Add to Library, Up One Level, New Folder, Feed Settings, Folder Settings; src: TextMouth/Views/Library/LibraryFolderSettingsTarget.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Models/AddToLibraryWording.swift, TextMouth/Views/Library/AddToLibrarySheet.swift -->

The toolbar's buttons for adding and for settings:

- Add to Library, a plus button between Up One Level, where that shows, and the edit mode button, opens the sheet of ways to add to the library (see [Adding books](adding-books.md)).
  It replaces the old Import, New from Text, and Add Feed buttons.
- Feed Settings or Folder Settings, between New Folder and the Sort menu, shows only in a folder of the Folders view: never at the top of the library, and in no other view.
  A feed's folder, the folder that lists the feed's episodes or articles, gets Feed Settings, even when it also holds books of your own; any other folder gets Folder Settings.
  - Feed Settings opens the feed's Feed Info, the sheet that Command-I opens on the feed's row (see [Podcasts and article feeds](feed-commands.md)).
    VoiceOver calls the button "Feed settings for" and the feed's title, as in "Feed settings for Planet Money", and its hint is "Opens the feed's settings: where its downloads go, what it lists and downloads, and what happens when an episode ends".
  - Folder Settings opens the Folder Settings sheet (below).
    VoiceOver calls the button "Folder settings for" and the folder's name, as in "Folder settings for Classics", and its hint is "Opens the folder's settings: what it holds, and what happens when one of its books ends".
- Folder or Feed Settings, in the Library menu after Remove from Reading List and among the Library actions of the Shortcuts tab of Settings, does what the button does for the folder the window shows.
  It has no key until you give it one.
  Where the window shows no folder, because it is at the top of the library or in another category, VoiceOver says "Open a folder first to see its settings".

## The Folder Settings sheet
<!-- id: folder-settings-sheet; keys: folder options, listening options, Open the next book in, When a book ends, Skip finished books; src: TextMouth/Views/Library/FolderSettingsSheet.swift, TextMouth/Models/FolderSettingsWording.swift, TextMouth/Models/ListeningOptions.swift, TextMouth/Models/NextBookWindow.swift -->

The Folder Settings sheet shows a plain folder's facts and how listening goes on from one of its books to another:

- Its title is "Folder Settings", and the folder's name is its heading.
  Under the heading are read-only rows.
  Each is one element that VoiceOver says as its label, a comma, and its value, and its value can be selected and copied:
  - "Location", the path of the folder that holds this one, or "Library Root" at the top of the library
  - "Books", the books in the folder and in every folder inside it, with how many are unopened, as in "12 books, 3 unopened"
  - "Subfolders" and "Feeds", each only when the folder has any
  - "Time remaining", only when it is known, as in "14 hours, 3 minutes remaining in total"
- Under a heading, "Listening", are three controls, each saved as you choose it.
  The pop-up button "When a book ends" offers "Use the global setting (…)", which names the Playback tab's When book ends choice, as in "Use the global setting (Continue to Next Book)", then "Play the book below", "Play the book above", and "Stop".
  Its hint is "Chooses what happens when one of this folder's books ends".
  The pop-up button "Open the next book in" offers "Use the global setting (…)", which names the Playback tab's Open the next book in choice, as in "Use the global setting (This Window)", then "This Window" and "A New Window".
  Its hint is "Chooses where this folder's next book opens."
  It is dimmed while the folder's books do not go on to another book when one ends, which is when "When a book ends" says Stop, or says Use the global setting and the global choice is not Continue to Next Book.
  Its hint then is "Available only while this folder's books go on to another book when one ends", and it keeps its choice for when they do.
  A dimmed choice is not in effect: Next in Folder and Previous in Folder then follow the global setting.
  The checkbox "Skip finished books", checked unless you clear it, has the hint "Applies when listening goes on to another book".
  What they do is under When a book ends, including Where the next book opens, in [Reader windows](reader-book-end.md).
  A folder's choices apply to the books directly in it, never to those in the folders inside it.
- Done closes the sheet, and so do Return and Escape, since nothing in the sheet takes typing.
  If another window deletes the folder while the sheet is open, the sheet says "This folder is no longer in the library." in place of the folder.

## When a file cannot be saved
<!-- id: when-file-cannot-be-saved; keys: save failure, full disk, Retry, Dismiss, unsaved changes, quit; src: TextMouth/Views/Library/PersistenceFailureBanner.swift, TextMouth/Services/PersistenceFailureCenter.swift, TextMouth/App/UnsavedChangesTermination.swift -->

If a file cannot be saved (a full disk or a missing volume, for example), a banner in the Library window says what is unsaved, with Retry and Dismiss buttons.
A Retry pressed while TextMouth moves its data directory, edits a folder, or rebuilds the directory stays enabled, says when the save will come, and saves once that ends.
Quitting while something is unsaved asks first.

## When a folder is deleted or renamed in another window
<!-- id: when-folder-deleted-renamed-another; keys: nearest folder, folder renamed, folder moved, index recovery, deleted folder; src: TextMouth/Views/Library/LibraryView.swift, TextMouth/ViewModels/LibraryViewModel+IndexRecovery.swift, TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift -->

A Library window showing a folder that another window deletes, as Delete Folder… or Delete Feed… can, goes to the nearest folder above it still in the library, and one showing a folder another window renames or moves follows it to its new place.
Nothing moves while the library's index is being recovered.

## Editing an audiobook's manifest
<!-- id: editing-audiobook-manifest; keys: manifest.json, Edit Manifest With, track book, audiobook of tracks; src: TextMouth/Models/BookManifestEditWording.swift, TextMouth/Services/BookManifestEditing.swift, TextMouth/App/MenuCommands.swift -->

An audiobook of tracks' row offers Edit Manifest in Default Editor and Edit Manifest With… in its context menu, after Edit Text's commands (see [The audiobook manifest](audiobook-manifest.md#editing-an-imported-books-manifest)).
