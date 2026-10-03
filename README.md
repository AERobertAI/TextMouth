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
  - A summary line gives each location's book count and its listening time remaining at the current speed.
  - If a file cannot be saved (a full disk or a missing volume, for example), a banner in the Library window says what is unsaved, with Retry and Dismiss buttons. Quitting while something is unsaved asks first.
- Reader windows:
  - Each book opens in its own window, and several can be open at once.
  - An open book follows what the library does to it elsewhere: a new title or author, a move to another folder, a renamed folder, or a moved data directory. Nothing reloads and speech carries on; an audiobook playing while its files move stops for a moment and plays on from the same place.
  - The Playback menu holds Play / Pause, Skip Forward and Skip Backward, speed, Where Am I?, Copy Reading Position, Search in Book, and Release Media Controls.
  - The Navigate menu holds Go to Library, Next Heading and Previous Heading, Show Headings, Show Sleep Timer, and Book Info.
  - The Bookmarks menu holds Toggle Bookmark, Show Bookmarks, and Next Bookmark and Previous Bookmark.
  - Headphone and media keys control the reader that is playing, or, when none is, the reader window used most recently.
  - The sleep timer runs for a set number of minutes, or until the end of the heading or the end of the document, as its sheet names them. One timer serves the whole app.
  - When a book ends, TextMouth stops, starts the book again, or continues to the next book in the folder, as Playback settings say. Each book can override that choice.
- Settings, in tabs:
  - Voice, Playback, Shortcuts, Text (substitution rules and repeated symbols), Sounds, Stats (listening time, streak, and books finished), Storage, and Miscellaneous.
  - The Shortcuts tab changes the shortcuts for reading, navigation, bookmarks, the sleep timer, and the library's actions. Open Book… and New from Text… always use Command-O and Shift-Command-T.
  - The Text tab's Repeated Symbols group sets how the voice reads one symbol written several times in a row, directly or with single spaces between, such as a separator line of asterisks. Say how many, the default, reads a run of 4 or more as a count, such as "7 asterisks"; Leave out skips the run with a pause; Repeat each symbol reads every one. "Collapse runs of at least" sets the shortest run that is counted or left out (2 to 99), and "Never collapse: read every symbol" reads every symbol whatever the style. The Symbols field lists the characters that can form runs; Reset to Default restores the standard list of ASCII symbols, bullets, dashes, the ellipsis, and box-drawing lines. Only speech changes: the text on screen and on a braille display keeps every symbol. A change applies from the next chapter spoken.

## Where TextMouth keeps your library

TextMouth keeps everything in one data directory: .TextMouth in your home folder unless you chose another place in Storage settings. That choice itself is kept in TextMouth's preferences, because config.json lives inside the directory it names. Moving the directory copies everything into a hidden folder beside the new location, checks the copy, then renames it into place in one step and switches to it. The new location must be an empty folder or one that does not exist yet. If anything else appears there, or the location is changed to lead somewhere else, while the copy is made, the move stops: TextMouth deletes only its own copy, leaves what appeared alone, keeps using the old folder, and says what appeared and where. A location that is a symbolic link counts as the folder it leads to, and messages name that folder too. The old folder is left where it was.

- library.json: the library index. It lists every book (title, author, format, folder, file path, reading position, bookmarks, and per-book settings), every folder, and each location's sort.
- library.json.unreadable- followed by a date and time: a preserved copy of an index that could not be read. When library.json cannot be read, TextMouth never overwrites it, and the Library window's Recovery Options… offer Try Again and Rebuild Library Index, which rebuilds the index from the books on disk.
- config.json: your settings, which you can edit by hand (see the next section).
- substitutions.json: the text substitution rules from the Text tab of Settings.
- reading_stats.json: listening statistics, kept by day.
- Logs: diagnostic logs. They never hold your substitution rules, and they name files by their place inside the data directory. They hold none of your books' text either, with one known exception: a CONTENT_INDEX_REJECTED line, written when a book's saved index is set aside and rebuilt, can quote the words of a heading.
  - textmouth_debug.log, the main log.
  - textmouth_timer.log, the sleep timer's log.
  - textmouth_transition.log, the speech engine's log.
  - Routine trace lines are written only while tracing is on: set the TEXTMOUTH_TRACE_LOG environment variable for one launch, or run `defaults write com.textmouth.TextMouth diagnosticTraceLogging -bool YES` until you turn it off again with `-bool NO`.
  - A log that reaches 2 MB is renamed with .previous added to its name, and a fresh one starts, so each log keeps at most two generations.
- Library: your books. Its folders are the library's folders, and each book is a package: a folder named after the book's title, author, date added, and identifier, ending in .tmb. A package holds:
  - The book's own file, under its original name. An audiobook made of several tracks keeps them in a folder instead; one converted from a DAISY audio ZIP also has a manifest.json listing its sections and the stretches of audio each one plays.
  - bookInfo.json: the book's record, with its metadata, reading position, bookmarks, per-book settings, and the index of its chapters and headings. It can rebuild a book's library entry if library.json is lost.
  - content.md: the text cache, the book's text as Markdown, so a text book opens without parsing its source again. TextMouth rebuilds it when the source file changes or when a newer version of TextMouth reads that format better.
  - removedFromLibrary.json: present only when you chose Remove from Library Only. It keeps the package on disk without the book returning to the library.
  - A folder whose name starts with .import- is an import in progress. Nothing else in TextMouth treats it as a book, and a later import into the same folder removes one that an interrupted import left behind.
- Archive Extraction: a temporary working folder for ZIP imports. Each import removes its own folder when it ends, and TextMouth removes any it finds left over at startup.

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
- `make check` runs the reproducibility gate, and `make check-selftest` tests the gate itself, both described below.
- `make generate` regenerates TextMouth.xcodeproj from project.yml. Run it after adding or removing a source or test file, and commit the changed project file with that file.
- `make resolve-packages` resolves the Swift packages exactly as Package.resolved pins them, and `make update-packages` resolves them again after a deliberate version change.
- `make xcode` regenerates the project and opens it in Xcode.
- `make clean` removes the build products.
- `make help` lists these targets.

### The hosted test suite

The tests are one XCTest bundle, TextMouthProductionTests, hosted by the app itself: Xcode launches TextMouth.app and runs the tests inside it, so they exercise the real code through `@testable import TextMouth`. New tests belong in TextMouthProductionTests/. The files under TextMouthTests/Sources/Tests are older scenario groups that project.yml lists one by one.

A process hosting tests never touches your data. When the XCTestConfigurationFilePath environment variable is set, as XCTest sets it, TextMouth keeps its data directory and its preferences in a sandbox folder named TextMouthTests- followed by the process number, in the temporary directory. In that process, VoiceOver announcements made through the app's announcer are recorded instead of spoken, and a test that leaves a reader window open fails.

- `make test` runs the whole suite. It runs `swift run` in TextMouthTests/, whose small runner calls:
  - `xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`
- The project's coding agents run the suite with complete concurrency checking, without parallel testing, and with a build folder of their own:
  - `xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete -derivedDataPath /tmp/TextMouth-DerivedData`
- To run one test class, add `-only-testing:TextMouthProductionTests/` followed by the class name, such as `-only-testing:TextMouthProductionTests/CountWordingTests`.
- A full run compiles the app and takes four to five minutes. A few tests skip in an ordinary run:
  - Opt-in tests that need a copied book or a library to profile, set up as TextMouthTests/README.md describes. That file also explains the playback profiling script, Scripts/profile-production-playback.sh.
  - Tests that read the accessibility structure SwiftUI builds, which it builds only while an assistive client such as VoiceOver is running.

### The make check gate

**Reproducible builds and `make check`.** TextMouth locks its Swift packages deliberately: `project.yml` requires an exact version of each direct dependency, and the committed `TextMouth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` pins every exact revision, including the transitive swift-cmark. Run `make check` before merging. It regenerates the project, resolves packages strictly from `Package.resolved` (failing if anything would change), builds Release, and runs the hosted test suite, printing one line per step and ending with PASSED or FAILED, with full logs in `build/check/`. To upgrade a package, change its version in `project.yml`, run `make update-packages`, review the `Package.resolved` diff, run `make check`, and commit both files. `make check-selftest` and `make check CHECK_ARGS=--dry-run` test the gate itself in seconds. GitHub Actions runs the same gate (`.github/workflows/check.yml`) on macOS 26 with Xcode 26.0.1 for every push to main and every pull request.

## Editing settings in config.json

config.json, in the data directory, mirrors TextMouth's settings so you can read and change them in a text editor, and copy them to another Mac.

- When it is read:
  - At launch, TextMouth applies the file first, because it may have been edited while TextMouth was closed.
  - While TextMouth runs, it notices a saved edit within a moment and applies it.
  - Every change you make in Settings saves the file again.
- How values are checked:
  - Each field is read on its own, so one mistake never discards the rest of the file. A number out of range is moved to the nearest allowed value, a value that cannot be read counts as missing, and each repair is noted in the debug log (Logs/textmouth_debug.log).
  - If the whole file is not valid JSON, TextMouth leaves it alone at launch and notes why in the debug log. The next settings change saves a fresh file over it.
  - An empty text field, an empty or unknown choice, and a speed or pitch of 0 all leave the current setting as it is.
  - A missing field also leaves its setting as it is, except for these, which are read as their defaults, so applying the file sets the default: rewindSmartMode, rewindSmartThreshold, sleepFadeOutDuration, sleepTimerAutoClose, punctuationPauseLevel, autoPlayOnNavigate, bluetoothMonitoringEnabled, bluetoothDisconnectDelay, restartTimerGestureEnabled, restartTimerGesturePattern, restartTimerGestureWindow, importDeleteBehavior, confirmBeforeDelete, and moveToTrashInsteadOfDeleting.
- Which settings it carries, by Settings tab:
  - Voice: selectedVoiceID, wordsPerMinute (50 to 650), pitchMultiplier (0.5 to 2), and selectedLanguage.
  - Playback: skipForwardUnit, skipBackwardUnit, shiftSkipForwardUnit, shiftSkipBackwardUnit, rewindOnResumeUnit, rewindSmartMode, rewindSmartThreshold, punctuationPauseLevel, autoPlayOnNavigate, endOfBookBehavior, sleepFadeOutDuration, sleepTimerAutoClose, playbackNavigationUnitControlMode, showBookmarkInPlaybackControls, and showSpeedInPlaybackControls.
  - Shortcuts: keyboardShortcuts, an object naming each action as Settings shows it, with a list of shortcuts written like `option+shift+command+b`. An empty list leaves the action without a shortcut, and a shortcut given to one action is taken from any other. An action the file leaves out keeps its shortcuts.
  - Text: substitutionsEnabled, the switch for the substitution rules, and the repeated-symbol settings: repeatedSymbolStyle ("repeat", "count", or "omit"), repeatedSymbolThreshold (2 to 99, or -1 to read every symbol; any negative number reads as -1, and 0 or 1 as 2), and repeatedSymbolSet (the symbols written together, such as "*-=_~#", each counted once, with letters, digits, and spaces ignored; empty keeps the current ones). The rules themselves are in substitutions.json.
  - Sounds: soundEffectsEnabled, soundEffectsVolume (0 to 1, in hundredths), and soundEffectAssignments, an object naming each playback event as Settings shows it, with the sound it plays; "None" plays nothing. An event the file leaves out keeps its sound.
  - Storage: importDeleteBehavior ("Keep Original", "Delete After Import", or "Ask Each Time"), confirmBeforeDelete, and moveToTrashInsteadOfDeleting. config.json is the only place these three are kept.
  - Miscellaneous: bluetoothMonitoringEnabled, bluetoothDisconnectDelay (1 to 10 seconds), restartTimerGestureEnabled, restartTimerGesturePattern, and restartTimerGestureWindow (0.5 to 10 seconds).
- Two fields describe this Mac rather than your preferences:
  - dataDirectoryPath: where the data directory is, empty for the default location. TextMouth always writes the folder in use. Changing it asks TextMouth to move the library there, exactly as Storage settings do, so emptying or deleting it while the library is elsewhere asks for a move to the default location. A move needs an empty destination; a value TextMouth cannot read keeps the folder in use.
  - lastOpenedBookID: the book opened most recently, which TextMouth records itself.
- What stays out of config.json: window positions, the last sleep timer you used, the preference that records the data directory's location, and the hidden switch for trace logging.

## Working on TextMouth with coding agents

Several coding agents can work on TextMouth at once, each in its own git worktree on its own branch, coordinated through a shared message board: the agent-bbs skill, in .claude/skills/agent-bbs/. Its SKILL.md is the full reference.

- The board is one SQLite file, .claude/agent-bbs/board.sqlite in the repository's main working tree, which git ignores. A standard-library Python script drives it, with no server: `python3 .claude/skills/agent-bbs/scripts/bbs.py`.
- Each agent registers its role, branch, and the files it expects to edit, claims files as it takes them on, and sees any overlap with another agent's claims.
- Agents post short messages about builds, commits, findings, and questions. A message tied to a file reaches whoever has claimed it.
- `bbs.py protocol` prints the rules for an agent's brief: register on start, read the inbox before each build and commit, post each commit, and release claims when done.
- `.claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh` runs a build while holding one of three machine-wide build slots, so that at most three wrapped builds share the development Mac's memory at once, and shows the agent as building meanwhile. `make check` uses such a wrapper when the TEXTMOUTH_BUILD_SLOT variable names one.
- The board's tests run with `python3 -m unittest discover -s .claude/skills/agent-bbs/tests`.
