# Speed and memory

Part of [TextMouth's documentation](../../README.md).

TextMouth was measured against a library the size of its developer's on October 3, 2026, and changed wherever a listener could notice what it cost. What changed in use:

- Starting to listen:
  - A session's first Play no longer waits while the system loads the voice: a text book's reader loads its voice silently, in the background, when it opens and whenever the voice changes.
  - When a text book opens, TextMouth prepares the speech of the chapter you are in (or, after a cover page, the first chapter with words) in the background, with your rules and settings, so Play starts without first preparing it. A setting changed before Play is applied as always. If you press Play on a long chapter before that is done, Play waits for it instead of preparing the chapter again, and TextMouth stays responsive meanwhile: the button reads Pause at once, and speech begins when the chapter is ready (for a 20 MB book of one chapter, about 4 seconds after it opens). Pressing Play/Pause while it waits stops it. When the chapter is ready while Where Am I? is speaking, speech begins once the announcement ends, and Play/Pause pressed during the announcement leaves the book paused. A shorter chapter is prepared at once, as before.
  - Opening a large book again, one whose text is a megabyte or more, reads the text TextMouth kept from the last open instead of reading the book's Markdown again, so the largest books open in about a tenth of the time with far less memory (see [Where TextMouth keeps your library](where-your-library-lives.md)).
  - Speech starts with a short passage, so the first word follows Play, a seek, or a skip sooner, and each next passage is handed to the voice while the one before it speaks, so speech runs on without waiting for TextMouth between passages.
  - A reader makes its speech engine only when speech first needs one, so it opens sooner, and an audiobook's reader never makes one.
  - The installed voices are listed once, in the background, after the first window opens, and again only when the system's voices change, as when a voice finishes downloading; only the very first launch, which must choose a default voice, lists them before that. The Voice tab and a reader's voice sheet show that list rather than asking the system each time.
- Long chapters:
  - Each substitution rule, the punctuation pauses, and the repeated symbols are applied in one pass through a chapter, so even a chapter as long as a whole book starts without a pause that grew with its length.
  - Each chapter's speech is prepared once, and used again for as long as everything it was prepared from stays the same: the chapter's text, its skipped sections, the substitution rules, the repeated-symbol settings, and the punctuation pause level. Changing the speed or pitch prepares nothing again, and the next chapter starts with the speech prepared for it while the chapter before it played.
  - A coming chapter too long to render ahead has its speech prepared in the background meanwhile.
- Audiobooks:
  - In an audiobook whose chapters are files of their own, each chapter follows the one before without the short silence of starting the player again. Where playback may have to stop or wait, it does so as before: at the book's last chapter, while the reader's own End of heading sleep timer stops at the chapter's end, as it does in an audiobook, whose chapters are its headings, and before a chapter whose file is only in the cloud, which downloads first.
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
  - While a book plays, its position is saved every 30 seconds into the book's own small record in its package, as before, but library.json, the index of the whole library, takes it within five minutes, or as the reader closes or TextMouth quits, rather than every 30 seconds. A feed's episode or article goes to its feed's own index the same way. A crash loses no more than before: the next launch takes the newer positions from the records (see [Where TextMouth keeps your library](where-your-library-lives.md)).
  - Saving a book's place no longer rewrites its index of chapters and headings, which has a file of its own, and library.json is written without line breaks, so listening writes a small fraction of what it did, which matters most in a library in the cloud, where every write is uploaded. library.json and each feed's index are also written only when what they hold differs from what TextMouth last read or wrote of them, so a save that changes nothing in one writes nothing to it; listening to a feed's episode, whose place is in its feed's index, usually leaves library.json alone.
  - A change in Settings is saved to config.json a moment after the last one, so dragging a slider writes the file once.
- Quitting while work is under way (0.4.4):
  - TextMouth waits for three kinds of work before it quits, and no longer cuts it off or hangs:
    - feed episodes downloading or waiting to download keep their place, for up to 3 seconds;
    - a book's text being read again in another encoding finishes, for up to 10 seconds;
    - a speech export stops with the chapters it finished kept, for up to 5 seconds.
  - When you press Command-Q, choose Quit from the TextMouth menu, or choose Quit in the Dock while any of that runs, a small window titled "Quitting TextMouth" appears and VoiceOver says the same words: "TextMouth is finishing up before it quits: " and what it is doing, then "It will quit as soon as that is done." TextMouth quits by itself when the work has ended.
  - What it says for each kind of work:
    - Downloads: "keeping the place of your feed downloads for next time".
    - A re-read: "reading a book's text again in another encoding", or "reading the text of 3 books again in another encoding" when several run.
    - A speech export: "stopping a speech export with the chapters it finished kept", or "stopping 2 speech exports with the chapters they finished kept" when several run.
    - Work of several kinds is said in one sentence, joined with "and".
  - The window does not take the keyboard from the window you were in.
  - Pressing Command-Q again, or choosing Quit in the Dock again, while TextMouth finishes no longer quits at once and cuts the work off. TextMouth says the same words again and goes on finishing.
  - Quit Anyway in the alert about changes that could not be saved still quits after the work has finished, and the alert is not shown a second time.
  - While such work was under way, choosing Quit Anyway, or answering an audio editor's or the Record window's question, used to leave TextMouth open with its windows stuck. That hang is gone: the quit now ends.
  - Log out, restart, and shut down wait for the same work as before, with the same words, and are not cancelled by it. If you log out while TextMouth is finishing for your Quit, the log out goes on when the work has ended.
  - Work that cannot end gives up after its limit, so the waits add up to about 18 seconds at most (3, 10, and 5).
- Opening and importing books:
  - Opening an EPUB no longer reads the book's package metadata from its file. The library keeps it for books imported since it began to, and for an older book the reader reads it in the background once the book shows, so Book Info has it a moment later, and keeps it on the book's row and in its record, so the book's later opens read nothing. Reopening a 1,447-chapter anthology from its kept text went from 112 to 65 milliseconds.
  - Importing a book, and rebuilding the text of the library's books, take far less time for large EPUB, HTML, Word, DAISY, and plain-text books: each EPUB document is parsed once, each file inside a book's archive is found without searching the whole archive, and HTML's emphasis and links, word counts, white space, and plain-text headings take time that grows only with the text. The text TextMouth makes is unchanged, byte for byte.
  - Opening a book whose text is cached copies far less of that text while splitting it into chapters.
  - Launch checks each book's package with fewer file-system calls, and works out in the background which text caches need rebuilding.
- Elsewhere:
  - In a library in the cloud, each reading of the books' states looks once at where the library lives, and while a book downloads, the frequent checks read only the downloading books. A library outside a cloud location stops at that one look.
  - Storage settings check the data directory in the background, so a slow or unplugged drive can't hold up the window.
  - A VoiceOver focus request for a window that closes before the request runs is dropped; it once could crash TextMouth.

PerformanceBaselineTests keep these gains: a number they measure that grows to more than twice its recorded baseline fails the test suite (see [The performance baselines](../developer/testing.md#the-performance-baselines), under [Building and testing](../developer/building.md)).
