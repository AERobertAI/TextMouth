# TextMouth

TextMouth is a native macOS application that reads books aloud with the Mac's text-to-speech voices and plays audiobooks. It is designed for people who read with VoiceOver and a braille display, and its rule is that every control has a spoken label, every value on screen has a spoken equivalent, and every action can be done from the keyboard.

This file is the guide to using, building, and testing TextMouth. ARCHITECTURE.md, in the same folder, explains how the code is organized and which part of the app owns each kind of data.

## What TextMouth reads

- Text books, spoken with any system voice:
  - EPUB files.
  - Word documents (.docx).
  - DAISY books, versions 2.02 and 3: a book's folder, its navigation or package file (ncc.html or a .opf file), or a ZIP holding the book.
  - PDF files. A page that holds only a scanned image is read with the Mac's own text recognition.
  - HTML, Markdown, and plain text files, whatever their text encoding and line endings.
  - Text you type or paste with New from Text.
  - In EPUB, HTML, Word, and Markdown books, a table is read a row at a time: each row is a paragraph of its own, with a pause after it, and the cells in a row are separate words.
- Audiobooks, played at the speed you choose:
  - Single files in MP3, M4A, M4B, WAV, AIFF, FLAC, ALAC, or AAC format.
  - A ZIP of audio tracks, which becomes one book with a chapter for each track.
  - A DAISY audio book in a ZIP, which becomes one audiobook whose sections are its headings. A section plays all of its heading's narration, even where it runs on into other audio files. A DAISY audiobook imported by an earlier version keeps one stretch of audio per section until it is imported again.
- TextMouth packages (.tmb folders) from another TextMouth library. A package keeps its reading position, bookmarks, and per-book settings.

## Finding your way around

- Adding books:
  - File menu, Open Book… (Command-O) imports the files you choose. Opening a supported file from Finder imports it and opens it.
  - File menu, New from Text… (Shift-Command-T) makes a book from text you type or paste.
  - Library menu, Import DAISY Folder… imports DAISY books kept as loose files, one folder per book.
  - A ZIP of several books imports each of them, and TextMouth offers to create a folder for them. The progress overlay's Cancel button stops a ZIP import after the book in progress.
  - When a book's content is already in the library, TextMouth asks whether to keep both, replace the existing book, or cancel.
  - Storage settings decide what happens to the original file after an import: keep it (the default), delete it, or ask each time.
  - These questions wait their turn. They are asked one at a time, in the order they arose, in the Library window where the import started, or in another Library window if that one has closed. When there is more than one, each title gives its place, as in "Duplicate Book Found, 2 of 5". Return chooses Keep Both or Create Folder, and Escape chooses Cancel, Keep, or No Thanks; Replace Existing and deleting an original file are never on a key. A question that appears while you are working in another window, such as a reader, waits in its Library window without taking focus or speaking.
  - A book opened from Finder opens once it is in the library and its questions are answered.
  - The progress overlay's Cancel button also withdraws the questions of the imports started before it was pressed, those waiting and any still to come: a duplicate's new copy is discarded, an original file is kept, and a ZIP's books stay where they are.
- The Library window:
  - Choose a category: Folders, All Items, No Folder, or Recent.
  - Sort by title, author, date added, last opened, file size, or your own manual order. Each folder and category remembers its own sort.
  - In manual order, Move Book Up and Move Book Down (Library menu), or dragging, rearrange a folder.
  - Edit Mode selects several books at once to move or remove them.
  - A book's context menu, and its actions in VoiceOver's Actions menu (VO-Command-Space), include Show in Finder, which selects the book's package in Finder. In a library in the cloud they also offer Download Now, Remove Download, and Keep on This Mac (see Keeping your library in the cloud).
  - A summary line gives each location's book count and its listening time remaining at the current speed, and, in a library in the cloud, how many of its books are in the cloud and how many are kept on this Mac.
  - If a file cannot be saved (a full disk or a missing volume, for example), a banner in the Library window says what is unsaved, with Retry and Dismiss buttons. Quitting while something is unsaved asks first.
- Reader windows:
  - Each book opens in its own window, and several can be open at once.
  - In a library in the cloud, a book whose files are only in the cloud downloads in its reader window before it opens (see Keeping your library in the cloud).
  - An open book follows what the library does to it elsewhere: a new title or author, a move to another folder, or a renamed folder. Nothing reloads and speech carries on; an audiobook playing while its files move stops for a moment and plays on from the same place, and one playing from its working copy in a library in the cloud doesn't stop at all. The data directory itself can't move while any book is open.
  - The Playback menu holds Play / Pause, Skip Forward and Skip Backward, speed, Where Am I?, Copy Reading Position, Search in Book, and Release Media Controls.
  - The Navigate menu holds Go to Library, Next Heading and Previous Heading, Show Headings, Show Sleep Timer, and Book Info.
  - The Bookmarks menu holds Toggle Bookmark, Show Bookmarks, and Next Bookmark and Previous Bookmark.
  - Headphone and media keys control the reader that is playing, or, when none is, the reader window used most recently.
  - The sleep timer runs for a set number of minutes, or until the end of the heading. Its sheet's Stop At section sets one that stops at the end of the chapter, before the next chapter starts, or at the end of the book, before the book starts again or the next book starts, for text books and audiobooks alike. Stopped at a chapter's end, the reader waits at the start of the next chapter, which Play starts, and VoiceOver says "Sleep timer expired at the end of the chapter. Playback paused."; stopped at the book's end, it says that the book finished and why nothing follows, as in "Finished: Moby-Dick. Next book not started because of the sleep timer." An audiobook fades out toward such a stop over the sleep timer's Fade out time, in Playback settings, when one is set; speech is not faded. One timer serves the whole app, and it belongs to the reader window that set it: another window's playback, even of the same book, never pauses or ends it.
  - When a book ends, TextMouth stops, starts the book again, or continues to the next book in the folder, as Playback settings say. Each book can override that choice.
- Settings, in tabs:
  - Voice, Playback, Shortcuts, Text (substitution rules and repeated symbols), Sounds, Stats (listening time, streak, and books finished), Storage, and Miscellaneous.
  - The Shortcuts tab changes the shortcuts for reading, navigation, bookmarks, the sleep timer, and the library's actions. Open Book… and New from Text… always use Command-O and Shift-Command-T.
  - The Text tab's Repeated Symbols group sets how the voice reads one symbol written several times in a row, directly or with single spaces between, such as a separator line of asterisks. Say how many, the default, reads a run of 4 or more as a count, such as "7 asterisks"; Leave out skips the run with a pause; Repeat each symbol reads every one. "Collapse runs of at least" sets the shortest run that is counted or left out (2 to 99), and "Never collapse: read every symbol" reads every symbol whatever the style. The Symbols field lists the characters that can form runs; Reset to Default restores the standard list of ASCII symbols, bullets, dashes, the ellipsis, and box-drawing lines. Only speech changes: the text on screen and on a braille display keeps every symbol. A change applies from the next chapter spoken.

## Speed and memory

TextMouth was measured against a library the size of its developer's on October 3, 2026, and changed wherever a listener could notice what it cost. What changed in use:

- Starting to listen:
  - A session's first Play no longer waits while the system loads the voice: a text book's reader loads its voice silently, in the background, when it opens and whenever the voice changes.
  - Speech starts with a short passage, so the first word follows Play, a seek, or a skip sooner, and each next passage is handed to the voice while the one before it speaks, so speech runs on without waiting for TextMouth between passages.
  - A reader makes its speech engine only when speech first needs one, so it opens sooner, and an audiobook's reader never makes one.
  - The installed voices are listed once, in the background, after the first window opens, and again only when the system's voices change, as when a voice finishes downloading; only the very first launch, which must choose a default voice, lists them before that. The Voice tab and a reader's voice sheet show that list rather than asking the system each time.
- Long chapters:
  - Each substitution rule, the punctuation pauses, and the repeated symbols are applied in one pass through a chapter, so even a chapter as long as a whole book starts without a pause that grew with its length.
  - Each chapter's speech is prepared once, and used again for as long as everything it was prepared from stays the same: the chapter's text, its skipped sections, the substitution rules, the repeated-symbol settings, and the punctuation pause level. Changing the speed or pitch prepares nothing again, and the next chapter starts with the speech prepared for it while the chapter before it played.
  - A coming chapter too long to render ahead has its speech prepared in the background meanwhile.
- Audiobooks:
  - In an audiobook whose chapters are files of their own, each chapter follows the one before without the short silence of starting the player again. Where playback may have to stop or wait, it does so as before: at the book's last chapter, while the reader's own sleep timer is set for the end of the chapter, and before a chapter whose file is only in the cloud, which downloads first.
- Memory:
  - The audio rendered for a chapter takes half the memory it did, and far less while it is being made. It is handed to the player a few seconds at a time, so a seek within the chapter prepares only the few seconds it is about to play.
  - macOS keeps a closed window for the rest of the session. A closed reader window now lets go of its book's text, headings, and audio, and a closed Library window stops drawing its list until it is shown again.
  - Importing a DAISY audiobook copies its audio out of the ZIP a piece at a time, instead of reading each audio file into memory whole.
- The library list:
  - The list is worked out once for each change of the library, and only the rows that changed are drawn again. While a book plays, only its row and the summary line follow its reading position, and a window in which nothing changes draws nothing.
  - When TextMouth rebuilds the text of many books at once, as at the first launch after an update that reads a format better, the finished books reach the list together, in batches, instead of one at a time.
  - A playing reader's Headings, Voice, Bookmarks, and Sleep Timer sheets are drawn again only when what they show changes, such as the heading being read.
  - Moving books to another folder, and renaming, moving, or deleting a folder while keeping its contents, move the books' packages in the background. The sheet says what it is doing, as in "Moving 3 books...", and keeps its buttons unavailable until it is done, and a change that moved 25 books or more ends with an announcement, as in "Done. Moved 30 books." Such a change first waits for an import, text extraction, or analysis under way, and VoiceOver hears what it waits for. It is refused while the data directory moves, while Rebuild Directory runs, or while another such change moves books, and the refusal says which, as in "TextMouth is moving books between folders. Try again when that finishes."
- Saving your place:
  - While a book plays, its position is saved every 30 seconds into the book's own small record in its package, as before, but library.json, the index of the whole library, takes it within five minutes, or as the reader closes or TextMouth quits, rather than every 30 seconds. A crash loses no more than before: the next launch takes the newer positions from the records (see Where TextMouth keeps your library).
  - Saving a book's place no longer rewrites its index of chapters and headings, which has a file of its own, and library.json is written without line breaks, so listening writes a small fraction of what it did, which matters most in a library in the cloud, where every write is uploaded.
  - A change in Settings is saved to config.json a moment after the last one, so dragging a slider writes the file once.
- Opening and importing books:
  - Importing a book, and rebuilding the text of the library's books, take far less time for large EPUB, HTML, Word, DAISY, and plain-text books: each EPUB document is parsed once, each file inside a book's archive is found without searching the whole archive, and HTML's emphasis and links, word counts, white space, and plain-text headings take time that grows only with the text. The text TextMouth makes is unchanged, byte for byte.
  - Opening a book whose text is cached copies far less of that text while splitting it into chapters.
  - Launch checks each book's package with fewer file-system calls, and works out in the background which text caches need rebuilding.
- Elsewhere:
  - In a library in the cloud, each reading of the books' states looks once at where the library lives, and while a book downloads, the frequent checks read only the downloading books. A library outside a cloud location stops at that one look.
  - Storage settings check the data directory in the background, so a slow or unplugged drive can't hold up the window.
  - A VoiceOver focus request for a window that closes before the request runs is dropped; it once could crash TextMouth.

PerformanceBaselineTests keep these gains: a number they measure that grows to more than twice its recorded baseline fails the test suite (see The performance baselines, under Building and testing).

## Where TextMouth keeps your library

TextMouth keeps everything in one data directory: .TextMouth in your home folder unless you chose another folder in Storage settings. Any folder can hold it, hidden or not: on this Mac, on an external or network drive, or in a cloud folder such as iCloud Drive, Dropbox, or Google Drive (see Keeping your library in the cloud). That choice itself is kept in TextMouth's preferences, with a bookmark of the folder and the identity of the library in it, because config.json lives inside the directory it names.

- Choosing a location:
  - Change Location… in Storage settings opens a folder chooser that shows hidden folders and can make a new folder; its button says Choose Location. The folder you choose becomes the data directory itself, with nothing added to its name.
  - TextMouth first looks at the folder, reading only what the file system says about it and downloading nothing, while the status line says "Checking" and the folder's path. Then it offers what the folder can hold, and VoiceOver announces each status line as it appears:
    - Move Library Here, for an empty folder, such as one just made in the chooser. The confirmation says that the library is copied there, checked, and used, with the current folder kept as recovery data, and what the place means: in a cloud folder, that the library, with its size, uploads in the background, and that a book only in the cloud needs an internet connection to open; on another drive, that the drive must be connected to open the library.
    - Use This Library, for a folder that holds a TextMouth library: its library-identity.json, or a library.json beside a Library folder. TextMouth switches to that library as it is, copying nothing, then quits and opens again on it. This is how another Mac restores a library from the cloud. The confirmation names both libraries, and says when the folder holds another copy of the library in use, such as the folder an earlier move left behind, which may lack the latest changes. Changes not yet saved are written first, and the switch is refused while some still can't be saved: choose Retry Saving, then try again.
    - For the folder the library is in already, the status line says it is the library TextMouth is using.
    - Anything else is refused, with the reason: a file rather than a folder, a folder holding other items, which it names, a folder inside the library, a folder in the Trash, one TextMouth can't read or isn't allowed to change, a cloud folder that isn't on this Mac yet, a missing folder whose enclosing folder is missing too, or another drive without room for the library.
  - Reset to Default moves a library in another folder back to ~/.TextMouth, the same way.
- Moving the library:
  - A move is refused while any book is open, naming the open books, and while books in a library in the cloud aren't downloaded: "3 books aren't downloaded. Download them first: select them in the library, then choose Download Now." It is refused too while another move, Rebuild Directory, or a change that moves books between folders is under way, saying which, as in "TextMouth is rebuilding its data directory. Try again when that finishes."
  - An import, text extraction, or book analysis under way finishes first, and the move's progress says which it waits for; any that start meanwhile wait until the move is over.
  - Moving copies everything into a hidden folder beside the new location, a book at a time, checks the copy, then renames it into place in one step and switches to it. The new location must be an empty folder or one that does not exist yet. If anything else appears there, or the location is changed to lead somewhere else, while the copy is made, the move stops: TextMouth deletes only its own copy, leaves what appeared alone, keeps using the old folder, and says what appeared and where. A location that is a symbolic link counts as the folder it leads to, and messages name that folder too. The old folder is left where it was.
  - While the library moves, every Library window shows a sheet with its progress, as in "Moving the library… 40 percent", and Cancel, which Escape also presses; Storage settings show the same. VoiceOver moves to the progress bar, and announces what the move waits for, where the library is going as the copy starts, each quarter of the copy, and how the move ended. Books can't be opened or added meanwhile; a book opened from Finder is imported once the move is over.
  - Cancel deletes the partial copy and leaves the library where it was, with no setting changed, and the status then says so, as in "Move cancelled. The library is still at /Users/you/.TextMouth." Once every item is copied, the move can only finish.
  - Quitting during the copy stops the move first, as Cancel does, or lets it finish once every item is copied, and then quits. A move still waiting to start its copy doesn't hold up quitting.
- When the library isn't available:
  - TextMouth checks the data directory at launch, before it creates or loads anything, reading only metadata. It checks again when the drive holding it is unmounted, or when a save finds its folder gone.
  - The default location is always available: it is created when it is missing, as on a first launch. A folder you chose is never created, nor any folder above it: a missing one is an unplugged drive, a signed-out cloud service, or a folder that was moved or deleted, and creating it would start an empty library in its place. A folder that was renamed, or a drive that mounted under another name, is found again through its bookmark, unless that leads into the Trash or to another library.
  - Otherwise every Library window shows Library Not Available in place of the library: the reason, such as "The drive “Backup” isn't connected." or "The folder is there, but it holds a different TextMouth library.", then where to choose another folder instead, "To use another folder, open Settings, Storage, and choose Choose Another Library or Use Default Location.", the folder's full path, which you can select and copy, and two buttons, Try Again, which Return presses, and Quit TextMouth. VoiceOver moves to the reason and announces it once. Meanwhile the library index isn't saved, and no book can be opened or added.
  - When library.json is only in the cloud, the reason says so, and TextMouth asks the sync service to download it; Try Again opens the library once it has arrived.
  - Try Again opens the library once it is back. When the library went missing while TextMouth was open, library.json is read afresh, and the session's newer reading positions are carried into it.
  - Storage settings say Library Not Available, with the same reason, and offer the ways out: Choose Another Library…, for a folder that holds a TextMouth library, and Use Default Location…, which uses the library in ~/.TextMouth or starts a new, empty one there. Either quits and opens TextMouth again on that library, and the confirmation lists the changes that couldn't be saved, which switching loses. Nothing is created at the missing location.

The data directory holds:

- library.json: the library index. It lists every book (title, author, format, folder, file path, reading position, bookmarks, and per-book settings), every folder, and each location's sort, as compact JSON, without line breaks. While a book plays, its reading position reaches the index within five minutes, or sooner when anything else in the library changes, when the book's reader closes, or when TextMouth quits; meanwhile the book's record in its package holds it (below).
- reading-checkpoints.json: present only while some books' records hold reading positions that library.json doesn't have yet. It names those books, so that a launch after a crash takes their newer positions from their records.
- library.json.unreadable- followed by a date and time: a preserved copy of an index that could not be read. When library.json cannot be read, TextMouth never overwrites it, and the Library window's Recovery Options… offer Try Again and Rebuild Library Index, which rebuilds the index from the books on disk.
- library-identity.json: which library this is, an identifier and the date the library was given it. It is written once, when TextMouth creates the library or first opens one an earlier version made, and never overwritten, so the library keeps its identity wherever its folder goes. TextMouth remembers the identifier it expects, so a folder that only has the right name, such as another drive called Backup, is never taken for your library.
- config.json: your settings, which you can edit by hand (see Editing settings in config.json).
- substitutions.json: the text substitution rules from the Text tab of Settings.
- reading_stats.json: listening statistics, kept by day.
- Sessions: in a library on another drive or in a cloud folder, a small file for each Mac that has the library open, holding the computer's name, when TextMouth was last active there, and its version. TextMouth writes this Mac's when the library opens, refreshes it every minute, and removes it at quit, and it removes any left untouched for 30 days (see Keeping your library in the cloud).
- Library: your books. Its folders are the library's folders, and each book is a package: a folder named after the book's title, author, date added, and identifier, ending in .tmb. A package holds:
  - The book's own file, under its original name. An audiobook made of several tracks keeps them in a folder instead; one converted from a DAISY audio ZIP also has a manifest.json listing its sections and the stretches of audio each one plays.
  - bookInfo.json: the book's record, with its metadata, reading position, bookmarks, and per-book settings, written within half a second of each change, and every 30 seconds while the book plays. It can rebuild a book's library entry if library.json is lost. While a record is only in the cloud, TextMouth neither reads nor writes it, and the book's changes are saved in library.json alone, without waiting, until the record is on this Mac again.
  - contentIndex.json: the index of the book's chapters and headings, with their word counts and, for an audiobook, its timing, written when the book is imported or its content is analyzed again, so saving the book's place never rewrites it. Earlier versions of TextMouth kept the index inside bookInfo.json: TextMouth moves it out the next time it saves such a book, and an earlier version that opens a book saved since finds no index there and analyzes the book once more.
  - content.md: the text cache, the book's text as Markdown, so a text book opens without parsing its source again. TextMouth rebuilds it when the source file changes or when a newer version of TextMouth reads that format better.
  - removedFromLibrary.json: present only when you chose Remove from Library Only. It keeps the package on disk without the book returning to the library.
  - A folder whose name starts with .import- is an import in progress. Imports build their packages here only while the data directory is on another drive than this Mac's own folders (below), and otherwise in this Mac's Import Staging folder. Nothing else in TextMouth treats such a folder as a book. The next import into the same library folder removes one that an interrupted import, or an earlier version, left behind, and each import that builds in this Mac's folder clears what interrupted imports left there.
- Archive Extraction: the working folder of ZIP imports while the data directory is on another drive than this Mac's own folders; otherwise ZIPs are extracted in this Mac's Archive Extraction folder (below). Each import removes its own folder when it ends. At startup TextMouth removes any left over, here and in this Mac's folder, and, while this Mac's folder is the one in use, removes this one once it is empty.
- Logs: the diagnostic logs, which TextMouth writes here unless Storage settings put them on this Mac, so they sit beside your books, move with the library, and sync with it when it is in the cloud. They never hold your substitution rules, and they name files by their place inside the data directory or this Mac's TextMouth folder. They hold none of your books' text either, with one known exception: a CONTENT_INDEX_REJECTED line, written when a book's saved index is set aside and rebuilt, can quote the words of a heading.
  - textmouth_debug.log, the main log.
  - textmouth_timer.log, the sleep timer's log.
  - textmouth_transition.log, the speech engine's log.
  - Routine trace lines are written only while tracing is on: set the TEXTMOUTH_TRACE_LOG environment variable for one launch, or run `defaults write com.textmouth.TextMouth diagnosticTraceLogging -bool YES` until you turn it off again with `-bool NO`.
  - A log that reaches 2 MB is renamed with .previous added to its name, replacing the older one in the same step, and a fresh one starts, so each log keeps at most two generations and a cloud drive uploads little. When the rename is refused twice, as a cloud drive can refuse one while it uploads the file, the log starts over instead, beginning with a LOG_ROTATION line saying why. TextMouth never downloads a log to add a line to it: one whose content is only in the cloud becomes the .previous generation, and a fresh one starts.
  - The Logs group in Storage settings chooses where they go: Log location offers Inside the data directory, the default, and In this Mac's Logs folder (~/Library/Logs/TextMouth). A change applies from the next line written; logs already written stay where they are. The line under the picker names the folder in use, and why while the logs can't go where it asks, and Show Logs in Finder opens that folder, saying so, aloud too, when Finder can't.
  - While the library isn't available, or the data directory or its Logs folder is missing, the logs go to ~/Library/Logs/TextMouth, and back to the data directory once it can take them. Each time they change place, the debug log they arrive in says why in a LOG_LOCATION line. TextMouth never creates a folder in the data directory to write a log: the Logs folder is made with the data directory's other folders.

TextMouth also keeps folders of this Mac's own, which never sync and keep working while the data directory isn't available:

- ~/Library/Logs/TextMouth: the diagnostic logs (see Logs, above), when Storage settings put them on this Mac, and while the data directory can't take them. Logs that earlier builds wrote only here stay here.
- ~/Library/Application Support/com.textmouth.TextMouth:
  - Working Copies: the copies that open audiobooks in a library in the cloud play from. Each is deleted when its reader window closes, and any that a crash left behind are removed the next time a copy is made.
  - Import Staging: the packages imports are building, while the data directory is on the same disk as this folder: the startup disk, which also holds the folders of iCloud Drive and other cloud drives. A data directory on another drive keeps them in its own library folders instead, so a new book is always put in place with one rename on one disk.
  - Archive Extraction: the working folders of ZIP imports, under the same condition.
  - Kept Books.json: the books kept on this Mac (see Keep on This Mac, in Keeping your library in the cloud), a choice another Mac sharing the library never reads.

## Keeping your library in the cloud

A data directory in iCloud Drive, Dropbox, Google Drive (streaming), or another cloud drive that macOS keeps in ~/Library/CloudStorage works as any other, and lets the sync service keep books only in the cloud to free space on this Mac: macOS removes the downloads of files it can fetch again when it needs space, and you can remove a book's download yourself. TextMouth recognizes such a folder from its path, tells each book's state from file-system metadata without downloading anything, and downloads a book when you open it. To put your library there, choose a folder in the drive with Change Location… and then Move Library Here; on another Mac signed in to the same drive, choose that folder and Use This Library (see Where TextMouth keeps your library). CLOUD-STORAGE-RESEARCH-2026-10-03.md and CLOUD-STORAGE-PLAN-2026-10-03.md, in the same folder as this file, explain the design.

- How each drive keeps a book: iCloud Drive syncs a book's package, its .tmb folder, as one item, while Google Drive and Dropbox sync each file in it. TextMouth tells which from the package's own sync flags and acts on what the drive syncs. On iCloud Drive it reads a book's state, and whether its changes have uploaded, from the package, and Download Now, opening a book, and Remove Download ask for the whole package, which comes to this Mac, or leaves it, all at once; on the other drives it does each of these file by file.
- In the Library window:
  - Each book's row shows and speaks its state after the New or Now Reading badge: Downloaded, In Cloud, Downloading 40%, Download Failed, or Waiting for Sync, which means the book's package hasn't arrived on this Mac yet. While a row speaks a download's percentage, it speaks the reading progress as "42 percent read", so the two never sound alike. A book kept on this Mac (below) shows and speaks "Kept on this Mac" after its state. A library on this Mac or on another drive looks and reads as before.
  - The summary line adds how many of the books shown are in the cloud, as in "3 books in the cloud": those not wholly on this Mac; and how many are kept on this Mac, as in "2 books kept on this Mac".
  - The states are read again when a Library window opens, when TextMouth becomes the active app, after books are added, moved, or removed, and every minute while a Library window is open. While any book downloads, even one Finder started, the downloading books are read every 2 seconds; a download that starts meanwhile shows when every book is next read, within a minute.
  - A book's context menu, and its actions in VoiceOver's Actions menu (VO-Command-Space), offer Download Now for a book in the cloud or one whose download failed, Remove Download for a downloaded book, Keep on This Mac, or Stop Keeping on This Mac for a book kept already (below), and Show in Finder, which selects the book's package. Each cloud service also has its own command for keeping a book on this Mac, in Finder: Keep Downloaded for iCloud Drive, Offline Access for Google Drive, and Make available offline for Dropbox.
  - With several books selected, these commands act on the selection and count the books they act on: "Download 3 Books", "Remove Downloads of 3 Books", "Keep 3 Books on This Mac", "Show 3 Books in Finder".
  - Download Now downloads the books one at a time, each showing Downloading 0% until its turn. It announces when it starts, and gives one summary when every book has ended, naming any book that wasn't downloaded and why.
  - Remove Download frees the space a downloaded book takes on this Mac, leaving it in the cloud. It deletes nothing from the cloud, so it doesn't ask first. It refuses a book open in a reader, a book kept on this Mac, and one with changes not yet uploaded, and says why in an announcement and an alert.
  - Book Info never waits for a download. For a book only in the cloud, it shows the details the library keeps, with "Some details appear once the book is downloaded.", and refuses to write changes into the book's EPUB file until the book is downloaded.
- Keep on This Mac:
  - A book's context menu, and its VoiceOver actions, offer Keep on This Mac, or Stop Keeping on This Mac for a book kept already, for any book in a library in the cloud, even one whose package hasn't arrived yet. With several books selected, each counts the books it acts on, as in "Keep 3 Books on This Mac". The Library menu has both commands too, for the books selected in the Library window in front; when nothing would change, VoiceOver says why, as in "No books are selected."
  - A kept book stays downloaded. One only in the cloud, or whose download failed, downloads at once, as Download Now downloads it, and VoiceOver hears "Keeping Moby-Dick on this Mac. Downloading it now", then the summary when the downloads end. One whose download the sync service removes, while TextMouth runs or before it started, downloads again, without an announcement, when the books' states are next read, and one whose download failed then waits five minutes before it is tried again.
  - Remove Download refuses a kept book: "The book is kept on this Mac, so its download can't be removed. Choose Stop Keeping on This Mac first." Stop Keeping on This Mac removes nothing: the download stays until the sync service or Remove Download removes it.
  - Keeping is this Mac's own choice, as Finder's Keep Downloaded is: another Mac that opens the same library keeps only the books chosen there. The choice is saved in this Mac's own Kept Books.json (see Where TextMouth keeps your library), never in the library.
- Opening a book:
  - A downloaded book opens at once. A book with files only in the cloud downloads first, in its reader window: "Downloading" and the book's title, the sync service's name, and a progress bar that VoiceOver moves to and reads as "2 of 3 files, 40 percent". While a single file is left and nothing has been counted yet, the bar gives that file's size and the time waited instead. Where the sync service reports how much of a file, or of a package iCloud Drive downloads whole, has arrived, the percentage counts that part too, never going back, so a book of one large file shows how far it has got.
  - VoiceOver hears the download start, then 25, 50, and 75 percent (or, while there is no percentage, the time waited, every 30 seconds), then "Downloaded. Loading."
  - Cancel, which Escape also presses, stops waiting, and the window then says the book isn't downloaded, with two buttons: Download, which Return presses, and Close.
  - A failure shows the reason with Try Again, which Return presses, and Close. Offline, the download fails at once: "This Mac is offline, so the book can't be downloaded from Dropbox. Connect to the internet and try again." A sync service that downloads nothing for 60 seconds is reported as perhaps paused, signed out, or not running. A book whose package hasn't arrived on this Mac yet says so.
  - The book is then read without ever waiting on the network. A file that went back to the cloud meanwhile is downloaded once more; if it has gone again, the reader says that part of the book isn't on this Mac.
- Playing an audiobook:
  - An open audiobook plays from a working copy: a copy of its package in this Mac's Working Copies folder, which on the same disk takes almost no extra space. So it keeps playing offline, or after the sync service removes the book's download. The copy is deleted when the reader window closes, and positions and bookmarks still save to the library.
  - When no copy can be made, a chapter whose file is only in the cloud downloads before it plays, in the same view, while the reader shows Playing. Pausing, with Play/Pause or when the sleep timer runs out, stops waiting, so the chapter doesn't start by itself later; it downloads again when you next play it, if it still has to. A failure stops at that chapter with a Chapter Not Downloaded alert offering Try Again.
  - A text book is read into memory when it opens, so it needs no copy.
- Background maintenance never downloads a book. The startup repair, the text cache and statistics passes, and Redo Text Extraction leave a book whose files are in the cloud as it is, decide nothing from what only the cloud knows, and catch the book up once its files are on this Mac; opening a book also rebuilds its text cache when that is out of date. Each pass that skipped books writes one MAINTENANCE_SKIPPED_IN_CLOUD line in the debug log, saying how many, and Redo Text Extraction says so in Storage settings too, as in "Done. 12 books in the cloud were skipped."
- Logs: they live in the library's Logs folder and sync with it, each kept to 2 MB with one older generation, so the uploads stay small, and TextMouth never downloads a log to write to it. To keep them off the cloud, choose In this Mac's Logs folder in Storage settings (see Where TextMouth keeps your library).
- Several Macs:
  - Use a library on one Mac at a time. While a library on another drive or in a cloud folder is open, TextMouth keeps a file for this Mac in its Sessions folder. When another Mac's file was refreshed in the last three minutes, TextMouth warns, once a session: "TextMouth is also open on “Study iMac” (active 2 minutes ago). Using one library on two Macs at the same time can lose reading positions and changes." Continue, which Return presses, keeps the library open here, and Quit TextMouth quits. It is only a warning: nothing is locked. A sync service's conflict copy of this Mac's own file never counts as another Mac.
  - config.json travels with the library, so a dataDirectoryPath that another Mac wrote is ignored when it names a folder this Mac doesn't have (see Editing settings in config.json).
  - TextMouth leaves alone the conflict copies a sync service makes of library.json, library-identity.json, config.json, reading_stats.json, substitutions.json, and a book's package and record, such as "library 2.json" or "library (1).json": it never reads one in place of the file it copies, nor adopts a copied package as a second book, and leaves each where it is. It doesn't merge what two Macs wrote.
  - While reading_stats.json or substitutions.json is only in the cloud, TextMouth neither waits for it nor saves over it, and asks the sync service for it. Meanwhile the statistics count only this session's listening, which is added to the file's totals once the file is on this Mac. The standard substitution rules stand in, and a change to them is reported as unsaved, with Retry; the file is read again whenever TextMouth becomes the active app and before each save, and once it is on this Mac its rules take the place of the standard ones, and that change is dropped.
  - Either file, when it can't be read, as a write cut short on another Mac can leave it, is kept beside itself before anything replaces it, its name followed by .unreadable- and the date and time, as an unreadable library.json is; the statistics then start afresh, and the standard rules stand in.
- What was tested: the opt-in tests in Testing on real cloud drives, below, passed against Dropbox, Google Drive, and iCloud Drive, and CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md lists the checks, with VoiceOver steps, still to be made by hand on each drive.

## Building and testing

### What you need

- A Mac with macOS 14 or later runs TextMouth. Development uses macOS 26 and Xcode 26.0.1, the version the continuous-integration job selects.
- XcodeGen generates TextMouth.xcodeproj from project.yml. Install it with `brew install xcodegen`; the development Mac and CI use version 2.45.3.
- `make check` reads the package pins with jq, which macOS 15 and later include as /usr/bin/jq.

### Make targets

Run these from the repository root:

- `make build` regenerates the project and builds the Release app as build/TextMouth.app. The full build log is build/xcodebuild-Release.log.
- `make debug` builds the Debug configuration instead.
- `make run` and `make open` build the app and open it.
- `make install` builds the app, copies it to /Applications, and registers it so it appears in Open With menus. `make uninstall` removes it.
- `make test` runs the hosted test suite, described below.
- `make check` runs the reproducibility gate, and `make check-selftest` tests the gate and the baseline-recording script themselves, both described below.
- `make perf-baselines` records new performance baselines after a deliberate change, as The performance baselines describes below.
- `make generate` regenerates TextMouth.xcodeproj from project.yml. Run it after adding or removing a source or test file, and commit the changed project file with that file.
- `make resolve-packages` resolves the Swift packages exactly as Package.resolved pins them, and `make update-packages` resolves them again after a deliberate version change.
- `make xcode` regenerates the project and opens it in Xcode.
- `make clean` removes the build products.
- `make help` lists these targets.

### The hosted test suite

The tests are one XCTest bundle, TextMouthProductionTests, hosted by the app itself: Xcode launches TextMouth.app and runs the tests inside it, so they exercise the real code through `@testable import TextMouth`. New tests belong in TextMouthProductionTests/. The files under TextMouthTests/Sources/Tests are older scenario groups that project.yml lists one by one.

A process hosting tests never touches your data. When the XCTestConfigurationFilePath environment variable is set, as XCTest sets it, TextMouth keeps its data directory, this Mac's own folders (its Logs folder, the working copies, and the import folders), and its preferences in a sandbox folder named TextMouthTests- followed by the process number, in the temporary directory. In that process, VoiceOver announcements made through the app's announcer are recorded instead of spoken, and a test that leaves a reader window open fails.

Each run deletes its sandbox as it finishes, and, as it starts, deletes in the background the sandboxes that earlier runs left behind, such as one that crashed. The system reuses process numbers, so a sandbox counts as left behind once no process with its number is running, or the one running started more than an hour after the sandbox was made. With TEST_RUNNER_TEXTMOUTH_KEEP_SANDBOX=1, a run keeps its sandbox for you to look inside, with a KEPT-SANDBOX.txt file in it that keeps later sweeps away; a later run given the same process number moves it aside, adding -kept- and a short suffix to its name. Delete a kept sandbox when you are done with it.

- `make test` runs the whole suite. It runs `swift run` in TextMouthTests/, whose small runner calls:
  - With `TEST_DERIVED_DATA=<folder>`, as in `make test TEST_DERIVED_DATA=build/DerivedData`, the runner builds in that folder, counted from the repository root, instead of Xcode's default DerivedData folder.
  - `xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- Every target compiles in the Swift 6 language mode: `project.yml` sets `SWIFT_VERSION` to `6.0` for the whole project, beside `SWIFT_STRICT_CONCURRENCY` set to `complete`, and TextMouthTests/Package.swift builds the test runner in the same mode, so Xcode, `make build`, `make test`, and `make check` all report the same diagnostics, and a data race the compiler can find is an error. The mode also checks at run time that main-actor code called from Objective-C, such as a closure handed to a framework callback, runs on the main thread, and stops the app if it does not. The project's coding agents run the suite without parallel testing and with a build folder of their own; the `SWIFT_STRICT_CONCURRENCY=complete` in their command is redundant, and harmless:
  - `xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete -derivedDataPath /tmp/TextMouth-DerivedData`
- To run one test class, add `-only-testing:TextMouthProductionTests/` followed by the class name, such as `-only-testing:TextMouthProductionTests/CountWordingTests`.
- A full run compiles the app and takes four to five minutes. Some tests skip in an ordinary run:
  - Opt-in tests that need a copied book or a library to profile, set up as TextMouthTests/README.md describes. That file also explains the playback profiling script, Scripts/profile-production-playback.sh.
  - Tests that read the accessibility structure SwiftUI builds, which it builds only while an assistive client such as VoiceOver is running.
  - Tests that read, through accessibility, the AppKit controls SwiftUI draws in a hosted window, such as steppers, sliders, and pop-up buttons, in a session that exposes none of them. Each run looks once, at a stepper of its own, and where it finds none exposed, every such test skips with one message, "This session exposes no accessibility elements for the AppKit controls in a hosted window", and the test log has one HOSTED_ACCESSIBILITY_UNAVAILABLE line. Where the controls are exposed, as on the development Mac, a control missing from a view, or left without its label, still fails its test.
  - The bookmark keyboard tests, which need Keyboard navigation turned on in System Settings.
  - The real-drive tests, which run only when you name folders on cloud drives for them (see Testing on real cloud drives).
  - The opt-in benchmarks of the performance work (below).
  - The performance baselines tests, while the Mac is busy, and on a Mac model or in a build configuration other than their baselines' (see The performance baselines).
- GitHub's macOS runner, where `make check` runs for every push to main and every pull request (see The make check gate), skips more tests than the development Mac. There SwiftUI builds no accessibility structure, a hosted window exposes none of its AppKit controls to accessibility, and keyboard navigation is off, so the three kinds of test above that read accessibility or need keyboard navigation skip rather than fail, as do the opt-in tests and benchmarks, and the performance baselines tests, whose baselines belong to the development Mac's model.
- The benchmarks of the performance work of October 3, 2026, time what each change made faster and print their figures in the test log. They are opt-in, since they take minutes or need a run of their own, and each group runs when its variable is 1; xcodebuild hands a variable whose name starts with TEST_RUNNER_ to the test host without that prefix:
  - TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS: the speech-preparation benchmarks at the sizes too slow to time in every run, and four that time the system synthesizer, muted, and the first speech engine. Three of those four mean something only when each runs alone, named with -only-testing, in a process of its own.
  - TEST_RUNNER_TEXTMOUTH_VIEW_BENCHMARKS: ViewsAndWindowsBenchmarks, which measure what a change of the library costs the list, what a playing reader costs its sheets, what a closed reader still holds, and how many test sandboxes the temporary folder holds.
  - TEST_RUNNER_TEXTMOUTH_BENCHMARKS: TextPipelineBenchmarkTests, which time the text pipeline's old and new code side by side, best in a Release build, as in `xcodebuild test -configuration Release ENABLE_TESTABILITY=YES -only-testing:TextMouthProductionTests/TextPipelineBenchmarkTests` with the rest of the usual arguments.
  - TEST_RUNNER_TEXTMOUTH_RENDER_BENCHMARK: what rendering a chapter's speech costs in memory and main-thread time. It takes about half a minute, and nothing is heard.
  - TEST_RUNNER_TEXTMOUTH_TRACK_CHANGE_BENCHMARK: how long an audiobook's next file takes to start playing, timed with silent files.
  - PersistenceCostTests and LibraryModelBenchmarkTests run in every run instead. They check what a change costs in counts that follow from the code alone, such as bytes written, file-system calls, and publishes of the library, never in time, which a busy Mac would change, and print their figures on lines beginning PERSISTENCE_COST: and PERFMODEL:.

### The performance baselines

PerformanceBaselineTests keep what the performance work of October 3, 2026 made faster from slipping back. They measure a library and books generated to the size of the developer's, never your own library, and run in every run of the suite, in about half a minute. They measure:

- launch with a 643-book library: reading library.json, the startup repair, and finding the text caches that need rebuilding;
- the first sort of the library by File Size, and one derivation of the All Items list for each of the six sorts;
- one live reading position update, and the bytes one 30-second reading checkpoint writes for a book whose record is as large as the developer's largest;
- opening a 1 MB EPUB until the speech of its first chapter is prepared, and opening a 3-file audiobook until it has loaded;
- preparing the speech of a 1,000,000-character chapter with the developer's 16 substitution rules, which TextMouthProductionTests/performance-substitutions.json keeps a copy of;
- the most memory a 40,000-character chapter's rendered speech takes while it is built, and what it keeps;
- extracting the 1 MB EPUB's text;
- the processor time of one cloud refresh of a library outside the cloud;
- the main-thread time one reader publish costs the open Headings sheet.

How they judge:

- Each number is the median of five runs, after one more that warms caches and is not counted. TextMouthProductionTests/performance-baselines.json holds each one's baseline, with the Mac model, build configuration, and date they were recorded on.
- A number more than twice its baseline is measured five times more, and the test fails only when the lower median is still more than twice its baseline. A number at 1.5 times its baseline or more prints a line beginning PERFORMANCE WARNING:, and one at half its baseline or less a line beginning PERFORMANCE NOTE:, since new baselines would tighten the check. Every number is printed on a line beginning PERFORMANCE:.
- The tests skip, printing PERFORMANCE SKIPPED: and why, while the Mac is busy (its one-minute load average above its number of cores), so other work cannot fail them, and on any Mac model or build configuration other than the baselines', where the numbers say nothing. With TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT=1 a busy Mac measures anyway: `make test PERFORMANCE_STRICT=1` sets it, and `make check` uses it. A baselines file that is missing or can't be read fails the tests rather than skipping them.

Recording new baselines:

- After a deliberate change to what they measure, run `make perf-baselines` on an otherwise idle Mac, adding `TEST_DERIVED_DATA=<folder>` to build in a folder of your own. It runs the tests alone with TEST_RUNNER_TEXTMOUTH_PERFORMANCE_RECORD=1: each test waits, for up to five minutes, until the Mac is quiet, and once every number is measured the file is rewritten with this Mac's model and today's date.
- It prints each old and new number, keeps xcodebuild's output in build/perf-baselines.log, and ends with PASSED or FAILED. Nothing changes unless the whole run succeeds. Review the file's diff and commit it with the change it records.
- The baselines recorded on October 3, 2026, on the development Mac (a Mac15,12: Apple M3, 8 cores, 8 GB), in a Debug build with VoiceOver running, each the median of five runs:
  - Launch with 643 books: 132.724 milliseconds.
  - First sort by File Size: 26.012 milliseconds.
  - One list derivation, in milliseconds: Title 4.200, Author 4.458, Date Added 1.056, Last Opened 2.874, File Size 2.789, Manual Order 4.172.
  - One live reading position update: 146.803 microseconds.
  - One 30-second checkpoint: 851 bytes.
  - Opening the 1 MB EPUB to its first chapter's speech: 208.406 milliseconds.
  - Opening the 3-file audiobook: 4.597 milliseconds.
  - Speech for the 1,000,000-character chapter with the 16 rules: 236.652 milliseconds.
  - Rendered speech of a 40,000-character chapter: 43.358 megabytes at its peak, 43.349 megabytes kept.
  - Extracting the 1 MB EPUB: 1,195.592 milliseconds.
  - One cloud refresh of a local library: 0.173 milliseconds of processor time.
  - One reader publish to the Headings sheet: 1.740 milliseconds of main-thread time.

### Testing on real cloud drives

CloudDriveIntegrationTests runs the cloud services against real sync services. It is opt-in: its tests skip unless the TEXTMOUTH_CLOUD_TEST_ROOTS environment variable lists folders for them.

- Make a folder named TextMouth Cloud Tests in each drive to test, and list the folders' full paths, separated by colons. xcodebuild hands a variable to the test host when you set it with the prefix TEST_RUNNER_, as in:
  - `TEST_RUNNER_TEXTMOUTH_CLOUD_TEST_ROOTS="$HOME/Library/CloudStorage/Dropbox/TextMouth Cloud Tests" xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:TextMouthProductionTests/CloudDriveIntegrationTests`
- When any entry isn't the full path of an existing folder with that name inside a cloud drive, or is listed twice, the tests fail and use no folder at all. CloudDriveTestSupportTests checks these rules in every ordinary run.
- Each test works only inside a new folder of its own, writes small files of random bytes there (the small-library test uses the repository's TestData books), and deletes the folder when it ends, even after a failure. Nothing else on the drive is read or changed, and the app's library stays in the test sandbox. With TEST_RUNNER_TEXTMOUTH_CLOUD_TEST_KEEP_SMALL_LIBRARY=1, the small library stays on the drive, for the checks made by hand. A run moves about 36 MB up and 10 MB down for each drive.
- On October 3, 2026, every test passed against Dropbox, which showed that:
  - Download and removal requests work: a test book's files uploaded within 5 seconds, their downloads were removed at once, and they downloaded again within a second through TextMouth's book service.
  - A file whose download was removed reports its real size, and a clone made before the removal stays readable.
  - A package renamed into the drive, as an import puts a new book in place, syncs as one book, and a hidden folder syncs within 4 seconds.
  - Remove Download refuses a book whose new file hasn't finished uploading.
  - Progress is reported only at 0 and 100 percent for small files, and a file's modification time moves by up to 118 nanoseconds when it downloads again, which is why TextMouth compares the times of a text cache's files to the microsecond.
- Later that day, after TextMouth learned to treat a book's package that iCloud Drive syncs whole as one item, every test passed against iCloud Drive and Google Drive too. Dropbox, whose files each carry their own flags, was not run again. The runs showed that:
  - iCloud Drive syncs a book's package as one item: the package carries the sync flags and the files inside it none, and a request to download or remove one of those files is refused as if the file didn't exist. Removing the package's download leaves the whole package in the cloud at once, nothing inside it can be looked up until it downloads again, and TextMouth's book service brought it back within a second. Google Drive syncs each file, as Dropbox does, though its package folders carry sync flags too.
  - iCloud Drive uploaded a test book within 10 seconds, and Google Drive within half a minute, since Google Drive waits 15 to 30 seconds before it starts uploading.
  - iCloud Drive publishes the progress of a package as a whole and none for the files inside it, and Google Drive each file's; on a quick download both reported only 0 and 100 percent.
  - Google Drive reports an evicted file's real size. iCloud Drive gives a file it downloads again a modification time in whole seconds, so a text book whose package came back has its files read once for their digests when it next opens, before its text cache is trusted; Google Drive moves the time by up to 107 nanoseconds, as Dropbox does.
  - On both, a clone made before a removal stays readable, a package renamed into the drive syncs as one book, a hidden folder syncs within half a minute, and Remove Download refuses a book whose new file hasn't finished uploading.
- CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md, in the same folder as this file, gives the commands for every drive and the matrix of checks to make by hand, with VoiceOver steps, for what these tests can't reach: TextMouth's own screens and commands on a real drive, and a drive that is paused, signed out, or offline.

### The make check gate

**Reproducible builds and `make check`.** TextMouth locks its Swift packages deliberately: `project.yml` requires an exact version of each direct dependency, and the committed `TextMouth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` pins every exact revision, including the transitive swift-cmark. Run `make check` before merging. It regenerates the project, resolves packages strictly from `Package.resolved` (failing if anything would change), builds Release and runs the hosted test suite, with the performance baselines tests measuring even on a busy Mac, and fails on any Swift warning in either build, about concurrency or anything else, naming the first five. It repeats, once each, the PERFORMANCE WARNING: and PERFORMANCE SKIPPED: lines those tests print; neither kind fails the gate, since a number more than twice its baseline has already failed its test. Both builds start from scratch: the gate first removes `build/DerivedData/Build` and `TextMouthTests/.build`, keeping the package checkouts, because xcodebuild prints a file's warnings only when it compiles that file. It prints one line per step and ends with PASSED or FAILED, with full logs in `build/check/` and the Release build's in `build/xcodebuild-Release.log`. A run takes about seven minutes on the development Mac (2 minutes for the Release build, 5 for the tests). To upgrade a package, change its version in `project.yml`, run `make update-packages`, review the `Package.resolved` diff, run `make check`, and commit both files. `make check-selftest` and `make check CHECK_ARGS=--dry-run` test the gate itself in seconds, and `make check-selftest` tests the baseline-recording script too. GitHub Actions runs the same gate (`.github/workflows/check.yml`) on macOS 26 with Xcode 26.0.1 for every push to main and every pull request.

## Editing settings in config.json

config.json, in the data directory, mirrors TextMouth's settings so you can read and change them in a text editor, and copy them to another Mac.

- When it is read:
  - At launch, TextMouth applies the file first, because it may have been edited while TextMouth was closed.
  - While TextMouth runs, it notices a saved edit within a moment and applies it.
  - Every change you make in Settings saves the file again, a moment after the last change, so a slider dragged through many steps writes it once, and quitting writes a save still waiting. An edit saved to the file in that moment is merged with the changes, not written over.
  - When config.json is only in the cloud, TextMouth neither reads it, which would wait for a download, nor writes over it, which would replace what another Mac saved: the settings on this Mac stand, and the first save that finds the file on this Mac merges it as an edit.
  - While the library isn't available, TextMouth neither reads, writes, nor watches the file, which may hold another library's settings. Once the library is back, a setting changed meanwhile keeps its new value, and every other one takes the file's.
- How values are checked:
  - Each field is read on its own, so one mistake never discards the rest of the file. A number out of range is moved to the nearest allowed value, a value that cannot be read counts as missing, and each repair is noted in the debug log (textmouth_debug.log, in the data directory's Logs folder, or in ~/Library/Logs/TextMouth when Storage settings put the logs there).
  - If the whole file is not valid JSON, TextMouth leaves it alone at launch and notes why in the debug log. The next settings change saves a fresh file over it.
  - An empty text field, an empty or unknown choice, and a speed or pitch of 0 all leave the current setting as it is.
  - A missing field also leaves its setting as it is, except for these, which are read as their defaults, so applying the file sets the default: rewindSmartMode, rewindSmartThreshold, sleepFadeOutDuration, sleepTimerAutoClose, punctuationPauseLevel, autoPlayOnNavigate, bluetoothMonitoringEnabled, bluetoothDisconnectDelay, restartTimerGestureEnabled, restartTimerGesturePattern, restartTimerGestureWindow, importDeleteBehavior, confirmBeforeDelete, and moveToTrashInsteadOfDeleting.
- Which settings it carries, by Settings tab:
  - Voice: selectedVoiceID, wordsPerMinute (50 to 650), pitchMultiplier (0.5 to 2), and selectedLanguage.
  - Playback: skipForwardUnit, skipBackwardUnit, shiftSkipForwardUnit, shiftSkipBackwardUnit, rewindOnResumeUnit, rewindSmartMode, rewindSmartThreshold, punctuationPauseLevel, autoPlayOnNavigate, endOfBookBehavior, sleepFadeOutDuration, sleepTimerAutoClose, playbackNavigationUnitControlMode, showBookmarkInPlaybackControls, and showSpeedInPlaybackControls.
  - Shortcuts: keyboardShortcuts, an object naming each action as Settings shows it, with a list of shortcuts written like `option+shift+command+b`. An empty list leaves the action without a shortcut, and a shortcut given to one action is taken from any other. An action the file leaves out keeps its shortcuts.
  - Text: substitutionsEnabled, the switch for the substitution rules, and the repeated-symbol settings: repeatedSymbolStyle ("repeat", "count", or "omit"), repeatedSymbolThreshold (2 to 99, or -1 to read every symbol; any negative number reads as -1, and 0 or 1 as 2), and repeatedSymbolSet (the symbols written together, such as "*-=_~#", each counted once, with letters, digits, and spaces ignored; empty keeps the current ones). The rules themselves are in substitutions.json.
  - Sounds: soundEffectsEnabled, soundEffectsVolume (0 to 1, in hundredths), and soundEffectAssignments, an object naming each playback event as Settings shows it, with the sound it plays; "None" plays nothing. An event the file leaves out keeps its sound.
  - Storage: logLocation, where the diagnostic logs are written ("dataDirectory", the default, or "machine"); and importDeleteBehavior ("Keep Original", "Delete After Import", or "Ask Each Time"), confirmBeforeDelete, and moveToTrashInsteadOfDeleting, which config.json alone keeps.
  - Miscellaneous: bluetoothMonitoringEnabled, bluetoothDisconnectDelay (1 to 10 seconds), restartTimerGestureEnabled, restartTimerGesturePattern, and restartTimerGestureWindow (0.5 to 10 seconds).
- Two fields describe this Mac rather than your preferences:
  - dataDirectoryPath: where the data directory is, empty for the default location. TextMouth always writes the folder in use. Changing it asks TextMouth to move the library there, exactly as Storage settings do, and emptying or deleting it names the default location. config.json can come from another Mac with a library in the cloud, so a request is ignored, with one CONFIG_FILE line in the debug log, when the folder it names doesn't exist on this Mac or already holds a TextMouth library: emptying the field moves the library back only when ~/.TextMouth exists and holds no library. A move needs an empty destination; a value TextMouth cannot read keeps the folder in use.
  - lastOpenedBookID: the book opened most recently, which TextMouth records itself.
- What stays out of config.json: window positions, the last sleep timer you used, the preferences that record where the data directory is (its path, a bookmark of its folder, and the identity of the library expected there), this Mac's identifier for the Sessions folder, and the hidden switch for trace logging.

## Working on TextMouth with coding agents

Several coding agents can work on TextMouth at once, each in its own git worktree on its own branch, coordinated through a shared message board: the agent-bbs skill, in .claude/skills/agent-bbs/. Its SKILL.md is the full reference.

- The board is one SQLite file, .claude/agent-bbs/board.sqlite in the repository's main working tree, which git ignores. A standard-library Python script drives it, with no server: `python3 .claude/skills/agent-bbs/scripts/bbs.py`.
- Each agent registers its role, branch, and the files it expects to edit, claims files as it takes them on, and sees any overlap with another agent's claims.
- Agents post short messages about builds, commits, findings, and questions. A message tied to a file reaches whoever has claimed it.
- `bbs.py protocol` prints the rules for an agent's brief: register on start, read the inbox before each build and commit, post each commit, and release claims when done.
- `.claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh` runs a build while holding one of three machine-wide build slots, so that at most three wrapped builds share the development Mac's memory at once, and shows the agent as building meanwhile. `make check` uses such a wrapper when the TEXTMOUTH_BUILD_SLOT variable names one.
- The board's tests run with `python3 -m unittest discover -s .claude/skills/agent-bbs/tests`.
