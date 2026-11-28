# Changelog

Part of [TextMouth's documentation](../../README.md).

Every version of TextMouth, newest first, and what changed for you in each.

## 0.6.1 (November 27, 2026)

### Choosing a voice while a book is playing
- A voice you choose in the reader, in Settings, or in a book's own settings now takes effect at once, most of all on the iPhone.
  Speech goes on in the new voice from the start of the word you were at, where before the old voice played to the end of the text.
- A book that is paused starts in the new voice when you press Play.
- While a sleep timer is fading the sound, the change waits until the fade is cancelled.

### A quieter reader on the iPhone
- Book content is one element for VoiceOver, about twelve lines tall and never more than 55% of the screen, so Play is always in view. The sentence being spoken is highlighted.
  The text follows it while the book plays, unless VoiceOver is reading the text or you scrolled it by hand in the last 5 seconds.
- Book Actions, after Return, holds Sleep Timer, Voice, Book Info, and Export this book. While a sleep timer runs, it also shows under Play with the time left, and focus goes to Play when it ends.
- Play opens the Sleep Timer from its actions, with a one-finger triple tap, or with a touch and hold.
- VoiceOver passes over Skip backward and Skip forward, since swiping up or down on Play does the same; they stay for touch, Voice Control, and Switch Control.
- Go To says the page and time at your place, as in "Page 112 of 300, 1:02:03".

### Building with Xcode 27
- TextMouth builds with Xcode 27.2, and the helper program that reads audio formats starts under macOS 27.
- Installing on your iPhone skips simulators, accepts device=, team=, and launch= in lower case, and says how to finish an Apple ID sign-in that Xcode left unfinished.

## 0.6.0 (November 26, 2026)

### Your library on your Mac and your iPhone
- TextMouth can keep your library in step between your Mac and your iPhone through a TextMouth Sync folder in iCloud Drive: Set Up Sync on the first device, in the Sync section of Settings, and Join Sync Folder on each other one.
- Sync carries the books you add and remove, each book's place, bookmarks, details, and voice and speed settings, your folders, and the reading list with its order.
- A book's files stay only on the devices where you download it or keep it; on the others it says In Cloud until you open it or choose Download Now.
- Sync runs at launch, every hour, when the network comes back, a few minutes after a change, and when you choose Sync Now: Command-Option-S or the Library menu on the Mac, and a VoiceOver action on the Library's summary on the iPhone.
- Keep on All Devices, in a book's commands, the Mac's Library menu, and Book Information, keeps a book's files on every device, and the reading list's books are kept too; they download after a sync on Wi-Fi or Ethernet, never on cellular data or in Low Data Mode.
- When a sync would remove many books at once, TextMouth holds the removal and says so until you choose Sync Now.
- Sync is off until you set it up, and it needs a library kept on the device itself, not one in a cloud folder; update every device to this version first.
- Remove Download frees a book's space on this device while it stays in iCloud Drive, once TextMouth has checked that iCloud Drive holds every file of it; the row then says In Cloud, and opening the book downloads it again.
- Books on this device, in the Sync section of Settings, is All books on the Mac or Books you open or keep on the iPhone, where the downloads of books you haven't opened for 7 days (Off or 1 to 30) are removed at a sync; kept books and the reading list's stay.
- "Syncing your library between your devices" lists what isn't synced yet.

### Export on the iPhone
- Export… in a book's actions and Export this book in the reader write the book into a folder you choose once, in every format but Word 97-2003, braille's BRF and PEF included.
- Spoken audio, as on the Mac, goes on with the screen locked and the sheet closed: the Live Activity shows its progress, and a card at the top of the Library has Stop. When iOS ends an export, the card says so, and the chapters already spoken are kept for a week.
- Export 12 Books… on a folder's row exports each book into a folder of its own, and Share… sends the files just exported to another app or person.

### Password-protected books
- TextMouth opens books with a password: ZIP archives, PDFs, and Word (.docx) documents. It asks for the password when you open the book, and Import Locked adds one without it.
- While a protected book is open its text stays in memory; nothing of it is written to disk or copied to iCloud Drive, and the library's row says Locked.
- Remember this password keeps it in this device's Keychain, so the book opens without asking next time.
- Remove Password, in the password panel, saves the book without its password, replacing its file.
- A password ZIP that TextMouth can't open yet is refused with words saying a password is why, never added empty.

## 0.5.12 (November 25, 2026)

### Braille in many languages on the iPhone
- The iPhone now carries liblouis's braille tables for many languages, not only English: 134 tables in 84 languages read braille files, compressed into 1.9 MB of the app.
- The iPhone's Settings has a Braille section. Braille code opens a list of every table, grouped by language, each row naming the code, how far it contracts, and its language, and VoiceOver says which one is selected. Braille file characters and Guess the braille code of new books are there too.

### Tables that only write braille
- Some tables, such as German, Chinese, Korean, and Czech, can write braille but can't read a braille file back. TextMouth offers them when you export braille, and never for reading braille files. The iPhone carries them for the export it doesn't have yet.
- On the Mac, VoiceOver's Czech, Latvian, Slovenian, and two Chinese tables are judged by the newer liblouis, so they are offered for export only. A book you already read with one keeps its text.
- The Mac no longer offers VoiceOver's Icelandic, Serbian, and one Portuguese table, which never worked because macOS lacks files they need.

### A Mac and an iPhone together
- A braille table chosen on one device shows as that table on the other, with its language, in Settings, Export, and Book Information.
- When one device lacks the other's table, it keeps its own and leaves the other's choice in config.json alone.
- An iPhone reads a book a Mac read with one of VoiceOver's tables when the iPhone has a table of the same name.

### Smaller and steadier
- Both apps keep their braille tables in one compressed file and unpack a table the first time it's used, so the Mac app's four tables take 57 KB instead of about 250 KB.
- On the iPhone, a braille translation stopped before it began now stops at once.

### Installing on your iPhone
- `make install-ios` builds the iPhone app and installs it on your own iPhone from the Mac's command line. "Installing on your own iPhone" in the iPhone build guide has the one-time steps.

## 0.5.11 (November 23, 2026)

### BARD braille books
- TextMouth reads braille books from NLS BARD. Add the ZIP as you downloaded it or its unzipped folder, and on the Mac the book's .bopf file too, and TextMouth reads all of the book's volumes as one book.
- In a book of several volumes, each volume starts with a heading, Volume 1, Volume 2, and so on, and the book's own headings sit one level below.
- The title, the author, and the braille code, UEB or EBAE, contracted or uncontracted, come from the book itself.

### Braille files with a stray long line
- A braille file with a few lines longer than the rest no longer loses its centered headings, because TextMouth now leaves such stray lines out when it measures the page's width.
- Every braille book is read again once at the first launch of this version, and your place follows its words; only a book with such stray lines reads differently.

### A smaller app
- The Mac app is 18.2 MB, down from 22.4 MB, and the iPhone app 14.0 MB, down from 17.3 MB.
- The compiler now optimizes the whole app at once for size, and the file that holds TextMouth's 25 languages is compressed better.
- `make install` builds this smallest app. Its last step takes several gigabytes of memory for a few minutes, so on a Mac with 8 GB, quit other heavy apps before installing.

## 0.5.10 (November 23, 2026)

### Your own words for TextMouth's interface
- On the Mac, the Interface Language group in Settings has Edit Interface Text…. It fills a file named interface_text.json in your library's folder with every line of the language you use, then opens it in your text editor.
- Each line in the file gives its text first, then its English and a note on where it appears. Change a line's text, save, and TextMouth uses your words at once. Lines you leave alone keep each update's better wording.
- Export Interface Text…, on the Mac and the iPhone, saves every line as it reads now and marks the ones you changed. Someone else can use your file, and every line in it applies for them.
- The group says how many of your lines are in use and lists any it set aside, each with its reason. For example, a line whose placeholders don't match its English is set aside.

### The language picker in every language
- The Interface Language picker's own label, hint, and announcement are now in all 25 languages, so after a switch the picker speaks the new language too.
- On the iPhone, switching to or from Arabic, Hebrew, Persian, or Urdu no longer leaves the list of languages open on the screen.

## 0.5.9 (November 22, 2026)

### Choose TextMouth's language in Settings
- Settings has an Interface Language setting: at the top of the Miscellaneous tab on the Mac, and in a section of its own on the iPhone.
- Choose System to follow your Mac's or iPhone's languages, or choose any of the 25 languages TextMouth speaks.
- Each language is listed by its own name first, then by its name in the language TextMouth is in now, such as "Español, Spanish", so you can find your own after choosing one you can't read.
- The change applies at once, without restarting TextMouth, and VoiceOver announces it. Some of macOS's or iOS's own words, such as the standard menu items, change the next time TextMouth opens.
- Your choice is also TextMouth's language in System Settings on the Mac and in Settings on the iPhone, and a choice made there shows in TextMouth.

### A smaller app
- The Mac app is 22.3 MB, down from 32.2 MB, and the iPhone app 17.2 MB, down from 27.1 MB.
- TextMouth keeps all 25 languages in one compressed file of its own, in place of macOS's and iOS's language files, and every line reads exactly as before.

## 0.5.8 (November 21, 2026)

### TextMouth in Urdu and Persian
- TextMouth's menus, buttons, messages, and VoiceOver hints are now also in Urdu and Persian: 25 languages in all.
- Both are written right to left in their own letters, so VoiceOver and a braille display read them as Urdu and Persian, not as Arabic.
- Each is a machine translation that uses one word for each thing across the whole app, which a native speaker will review.

### Better wording in every language
- The careful machine review that 0.5.7 began has now read every string in every language, and reworded about 4,300 more that were wrong or awkward.
- This time it read Korean, Italian, Turkish, Indonesian, Bengali, Polish, Vietnamese, Ukrainian, Thai, Traditional Chinese, Dutch, Swedish, Hebrew, Urdu, and Persian.
- A path to a setting, such as System Settings, Accessibility, Spoken Content, no longer has ">" between its steps in any language, so VoiceOver doesn't say "greater than" in the middle of it.
- Ukrainian uses macOS's own names for System Settings, Accessibility, Undo, and Quit.
- In Traditional Chinese, Cancel Feed Downloads no longer sounds like Unsubscribe, and in Thai, an action that has finished is announced as done, not as a command.

## 0.5.7 (November 21, 2026)

### TextMouth in twelve more languages
- TextMouth's menus, buttons, messages, and VoiceOver hints are now also in Hindi, Arabic, Bengali, Indonesian, Vietnamese, Turkish, Thai, Polish, Traditional Chinese, Dutch, Swedish, and Hebrew: 23 languages in all.
- Arabic and Hebrew are TextMouth's first languages written right to left.
- Each new language is a machine translation that uses one word for each thing across the whole app, which a native speaker will review.

### Better wording in nine languages
- A second, more careful machine review read every string in Spanish, French, Brazilian Portuguese, Simplified Chinese, Hindi, Arabic, Russian, Japanese, and German, and reworded about 1,900 that were wrong or awkward.
- In Simplified Chinese, a copy-protected Kindle book no longer says that TextMouth can't read copyrighted books.
- Spanish says "auriculares" for headphones, not "audífonos", which in Spain are hearing aids.
- A sentence with a count now reads right for every number, and a button's name in a sentence is set off, so it isn't heard as an ordinary word.

## 0.5.6 (November 20, 2026)

### TextMouth in nine more languages
- TextMouth's menus, buttons, messages, and VoiceOver hints are now also in Italian, French, Brazilian Portuguese, German, Russian, Ukrainian, Simplified Chinese, Japanese, and Korean, besides English and Spanish.
- TextMouth appears in the first of your Mac's or iPhone's languages that it has. To choose its language alone, use System Settings, General, Language & Region, Applications on the Mac, or Settings, TextMouth, Language on the iPhone.
- Each new language is a machine translation, which a native speaker will review.

### A manifest edit is never lost
- When you saved a book of tracks' manifest twice in quick succession, TextMouth could put the first save's title back over the second. It no longer writes anything back when it takes your edit.

### A smaller audio converter
- The converter that reads the audio formats macOS and iOS can't is about 0.6 MB smaller. It converts somewhat more slowly, still hundreds of times faster than the audio plays.

## 0.5.5 (November 20, 2026)

### Smaller apps
- The Mac app is about 1 MB smaller and the iPhone app about 0.6 MB.
- Every word reads the same as before, in English and in Spanish.

## 0.5.4 (November 19, 2026)

### Lossless audio on the iPhone
- The iPhone now imports True Audio, WavPack, and Monkey's Audio files with TextMouth's own readers, as the Mac does, and each becomes the same book.
- A hybrid WavPack book keeps its full quality on the iPhone only when you add it with Import Folder or in a ZIP: Open Book and "Open in" take the file without its .wvc correction file, so it becomes AAC.

### Audio that TextMouth's converter reads
- A symbolic link to a good file converts.
- Copy-protected Matroska and WebM files are named as such, with "TextMouth cannot open copy-protected files."
- A partly damaged file imports with the damaged stretch kept as silence, so its length and chapters hold, and TextMouth says so: "Part of “Lecture.wma” could not be decoded and is kept as silence."

### A crash fixed
- TextMouth could crash when a book's window opened as TextMouth started, as it does when you open a ZIP from Finder.
- It no longer does.

### TextMouth speaks Spanish
- On a Mac or iPhone set to Spanish, all of TextMouth now appears and speaks in Spanish.
- The Spanish is a machine translation, which a native speaker will review.

### The whole interface can be translated
- Every word in TextMouth's windows can now be translated, on the Mac and the iPhone, not only the sleep timer, the bookmarks, and the Reading List.
- English and Spanish are complete so far.

### Shorter VoiceOver hints
- The VoiceOver hints of the sleep timer, the bookmarks, and the Reading List are shorter: each says what the control does once, without repeating its label or naming the key.
- Settings, Playback has a shorter hint for Open the next book in, and so do Feed Info and Folder Settings.
- VoiceOver hints and explanations are shorter across the rest of the app too, each keeping every fact it gave.

### Small wording fixes
- A count of one says "1 item", not "1 items".
- Numbers of 1,000 and more are grouped, as in "1,000 books".
- A list of two books joins them with "and", as in "A and B".

## 0.5.3 (November 18, 2026)

### Audio that macOS can't read, on the iPhone
- The iPhone now imports WMA, Matroska and WebM, AVI, Flash video, RealMedia, and Speex audio, and the sound of WMV video, as the Mac does, with the same converter, which TextMouth carries inside the app.
- Each file becomes the same book as on the Mac: the same sound, chapters, title, and author.
- Before, the iPhone refused these files and said to add them on your Mac.
- Musepack is accepted the same way, but no Musepack file has been tried yet, on the Mac or the iPhone, so it may fail.
- A copy-protected Windows Media file is told first, with the Mac's sentence: "TextMouth cannot open copy-protected files."
- The iPhone app is 2.4 MB larger, 16.1 MB in all, for the converter, and the Licenses folder in it holds FFmpeg's licence.
- The iPhone still refuses Ogg and the audio the Mac converts with Apple's converter, such as Opus, AC-3, AMR, MP2, and CAF, with "“Radio Drama” is in Ogg, which TextMouth on iPhone can't play yet. Add it on your Mac, then send the book here."

### Switching apps on the iPhone
- Time limits on the iPhone now count only the time TextMouth is running, for the converter and for braille.
- Switching to another app in the middle of an import no longer stops it for taking too long.
- Before, switching apps in the middle of a braille translation could stop braille until TextMouth was closed and opened again, with "TextMouth stopped the braille translation earlier because it took too long, and won't try again until TextMouth is closed and opened again."

### Memory on the iPhone
- The converter keeps 512 MB of the app's memory free, or half of what was free when it began, if that is less, so that iOS does not end TextMouth in the middle of a book.
- A file that would take more is stopped with "Converting tones.wma was stopped because the app's memory grew by more than 1700 MB while it ran."
- A phone that began with little memory free says "Converting tones.wma was stopped because the iPhone had only 400 MB of memory free when it began, and TextMouth keeps half of that free."

### On the Mac and the iPhone
- A file with a piece of sound too large for TextMouth to decode, as no good file has, is refused with "TextMouth can't convert “Radio.mkv”: part of its sound is stored in one piece too large for TextMouth to decode."

### Deep chapters and slow audio
- A book with a chapter nested too deeply no longer reads out or exports its markup: the reader, the speech, and the Plain Text export now give that chapter's words as written.
- The message after audio took too long now says to close and reopen TextMouth: "TextMouth stopped reading this audio earlier because it took too long, and won't try again until TextMouth is closed and opened again."

### Not changed
- How any other format imports, reads, or plays.

## 0.5.2 (November 17, 2026)

### Audio that macOS can't read
- WMA, Speex, Musepack, WebM, Matroska, AVI, Flash video, and RealMedia audio now import with a converter that TextMouth carries inside the app, so nothing needs installing.
- Before, these formats needed the free program ffmpeg installed with Homebrew, and an import without it said how to install it.
- TextMouth no longer looks for an ffmpeg on your Mac for the import, so a Mac that has one and a Mac that has none import the same way.
- The Use ffmpeg for filters switch still covers the audio editor's filters alone, and still uses an ffmpeg you install.
- The app is 2.5 MB larger, 21.0 MB in all, for the converter.
- The About window names FFmpeg, which TextMouth's converter is built from, under the GNU Lesser General Public License, and the Licenses folder in the app holds its licence.

### The converter's safety
- The converter reads a file only after confining itself with macOS's computing-only sandbox: it can read that one file and answer TextMouth, and open no other file, make no network connection, and start no program, whatever the file holds.
- If macOS will not confine it, it reads nothing, and the import says "TextMouth's converter could not make itself safe before reading “Lecture.wma”, so it did not read the file. Install TextMouth again, then import the file again."
- A damaged or hostile file that makes the converter stop now ends that file's import with "TextMouth's converter stopped unexpectedly while reading “Lecture.wma”. The file may be damaged." and TextMouth keeps running.
- A converter that has finished a file but does not end is ended after two seconds without failing the import, and one that writes more than a file should is stopped sooner.
- The converter is built from FFmpeg 9.0.2 with five fixes for known security problems in it.
- If TextMouth has lost its converter, which only a damaged copy of the app can, a file says "TextMouth can't convert WMA files because its converter is missing from the app. Install TextMouth again, then import the file again."

### What changed in these imports
- A CUE sheet over a WMA or Matroska file is now checked against the file's real length, as a sheet over any other audio is.
- AAC audio of two channels or fewer inside these formats is now decoded and written again as AAC, where before it was copied as it was.
- Sound whose rate or number of channels changes partway through, such as joined recordings, is converted to the rate and channels the file begins with, as the installed ffmpeg did before.
- Only a change by more than TextMouth can follow is refused, with "TextMouth can't convert “Radio.mkv”: its sound changes its rate or its channels partway through, by more than TextMouth can follow."
- A Musepack file named .mpp is told by its bytes, and no longer by its name, since Microsoft Project uses that name too.
- A tag longer than 4,096 bytes is cut at that length, and a tag with a damaged letter is left out.
- A folder whose name has a letter such as é no longer makes TextMouth lose what the Mac's own audio tool says about the files in it.

### Exporting books
- When an export meets a chapter that nests quotes, lists, or emphasis more than 128 levels deep, it now asks what to do, in an alert over the Export dialog, where before it refused that book's file.
- The alert says "Chapter 2 of Deep Notes nests too deeply", and its buttons are Export as Written, Export Every Such Chapter as Written, and Cancel Export.
- Export as Written writes that chapter as plain paragraphs of its lines, with its quote and list marks kept as characters, in Markdown, HTML, RTF, Word 97-2003, EPUB, BRF, and PEF, and exports everything else as usual.
- Return presses Export as Written, and Escape presses Cancel Export, which stops the whole export and leaves the files already written.
- The Plain Text export does not ask, and still writes such a chapter with the marker comments and backslashes of TextMouth's own text in it.

### Audio in forms TextMouth can't decode
- A valid audio file whose samples are stored as integers deeper than 32 bits, or as 16-bit or 24-bit floating-point numbers, is no longer called damaged.
- It says what is wrong instead, as in "“Talk.wav” uses 64-bit integer samples, which TextMouth can't play. Convert it to 16-bit or 24-bit integer samples, then import it again."
- The same sentence is said for a WAVE, AIFF, or CAF file imported by itself, as a track of a book, or to be converted, and a floating-point one says "16-bit floating-point".
- A 20-bit CAF file and a 20-bit Apple Lossless file now import, written at 24 bits, which holds every sample; before, the import said "failed its check: its audio cannot be decoded".
- An audio file of 17 to 20 bits is written at 24 bits in the same way.

### On the iPhone
- The iPhone still refuses WMA, Matroska, and the other formats only the Mac's converter reads, and its sentence now ends "Add it on your Mac, then send the book here."
- The iPhone now reads BRF, BRL, and PEF braille books, translated to print inside the app with the four English braille tables it carries.
- A braille book that needs one of the Mac's own tables is refused on the iPhone with "“Manuel” needs “fr-bfu-g2.ctb”, one of a Mac's own braille tables, which TextMouth on iPhone doesn't have. Add it on your Mac, then send the book here."
- The iPhone has no Braille settings, no Braille Code pop-up, and no export yet, and it reads every braille book with the Braille tab's defaults.
- A braille translation that runs far past its time limit is stopped, and the iPhone then says "TextMouth stopped the braille translation earlier because it took too long, and won't try again until TextMouth is closed and opened again." until you close TextMouth and open it again.
- The iPhone app is 0.5 MB larger, for liblouis and its tables.

### Not changed
- How any other format imports, reads, or plays.

## 0.5.1 (November 16, 2026)

### Editing audio
- A book whose audio is stored as 64-bit floating point samples can now be edited, saved, and exported. Before, a filter, a save, or an export of such a book could close TextMouth.
- If the system still refuses to write an edited book's audio, TextMouth keeps running and says so: "The edits couldn't be saved. The edited audio couldn't be written." for a save, and "The audio couldn't be exported." followed by the same sentence for an export.
- Saving the edits of a 24-bit Apple Lossless or FLAC book no longer lowers it to 16 bits, and a WAVE or AIFF export of one keeps its 24 bits. A 20-bit book is written as 24-bit.

### Moving the library
- A substitution rule, listening statistics, or filter preset changed while the library is being copied is now saved again in the moved library. Before, it could stay in the old folder, and TextMouth had said it was saved.
- Changing a setting or saving while the library is copied no longer makes the move fail with a message such as "The file couldn't be opened because there is no such file."
- A filter preset saved for the first time during a move is no longer missing from the moved library, and a Filter Presets list left open through a move saves into the moved library afterwards.

### Exporting books and editing their text
- A chapter whose quotes, lists, or emphasis nest more than 128 levels deep no longer closes TextMouth when you export the book.
  The export writes no file for that book and says which chapter, as in "Chapter 3 of this book nests quotes, lists, or emphasis more than 128 levels deep, which TextMouth can't export safely.
  Choose Edit Text, flatten the nesting, and save; then export again."
  The other books of the export are written.
- Edit Text refuses a save that would put such a chapter into a book, as it refuses other saves it can't take, and says which chapter.
  It says "Text not updated: chapter 2 of the edited text of Moby-Dick nests quotes, lists, or emphasis more than 128 levels deep, which TextMouth can't read safely.
  Flatten it in your editor and save again, or undo the change; until then, the book keeps the text it had."
- The count includes the lines of a code block, and counts every two columns of indentation as a level, so a code line of 129 ">" marks, or of 258 spaces before "- ", is refused too.
  No real book comes near the limit: the deepest nests 12 levels.

### Not changed
- How any book reads, plays, or is laid out.

## 0.5.0 (November 16, 2026)

### New formats
- Pictures of pages (.png, .jpg, .jpeg, .heic, .heif, .tif, .tiff) and comic book archives (.cbz) are books: TextMouth reads the words on each page with the Mac's own text recognition, a chapter for each page.
- Importing one counts the pages, as in "reading its text: 3 of 12 pages", and Cancel stops it before the next page.
- Text recognition knows nothing of a comic's panels or speech balloons, so the words of a page of panels may come in another order than the story's.
- A ComicInfo.xml in a comic gives its title, writer, deleted pages, and cover titles. A .cbr (RAR) archive is not read.
- A picture inside a ZIP of books, an audiobook's tracks, or a DAISY archive is not a book, and a ZIP of only pictures imports nothing: rename it to .cbz.
- PLS and XSPF playlists (.pls, .xspf) import as an audiobook of the files they list, as M3U playlists do. A .pls that is a pronunciation lexicon is refused, and says to use Import Rules… in Settings.
- In Settings, the Text tab has Import Rules… and Export Rules…: a W3C pronunciation lexicon adds its spelling-to-words entries as substitution rules, up to 5000 at a time, and your plain text rules that are on can be saved as one.
- A refused file now says what to do next for Pages, Keynote, Numbers, WordPerfect, Compiled HTML Help, DjVu, XPS, RAR, and copy-protected audio, for example "Export Pages documents from Pages as Word documents or EPUB books, then import those."

- CUE sheets (.cue) give an audiobook its chapters: a sheet added alone imports the files it names as one book, and a sheet in a folder or ZIP of tracks arranges them. A FLAC file's own CUE sheet block works too. A sheet that runs past its audio is left unused, with a notice.
- Chapter markers in WAV, AIFF, and CAF files, and CHAPTER comments in Ogg files, become chapters, and the converted .m4a keeps them.
- Audacity label files (.txt) beside a folder's audio give headings, and a book's headings or bookmarks export as labels.
- WMA, Speex, Musepack, WebM and Matroska audio, and the sound of AVI, WMV, FLV and other videos import when ffmpeg is installed: TextMouth converts them with it, keeping tags and chapters. Without ffmpeg, the refusal says how to install it.
- TTA, WavPack, and Monkey's Audio files import with readers built into TextMouth, with no ffmpeg needed.
- Copy-protected files, such as Audible's .aa and .aax, are refused with "TextMouth cannot open copy-protected files."

### Listening and editing
- Save and Export write a book's chapters as markers into WAV, AIFF, and CAF files, and say when a marker could not be written. Export Audio has a checkbox, "Also write the markers as Audacity labels", off each time.
- Saving or exporting an MP3 after cutting it no longer leaves a short silence of about a tenth of a second at the cut, and no longer sometimes fails with "The edited audio couldn't be written."
- To remove an old gap from a book saved before, choose Revert to Original in the audio editor, redo the edits, and save.
- A text book holds less memory while it plays or sits paused: about 15 to 21 MB less for a novel's chapter, which is the next chapter's audio.
- That audio is now made only in the last minutes of the chapter you are in (at least 5 minutes before its end, earlier when the next chapter is long).
- A book left paused for 5 minutes lets that audio go, and makes it again when you resume near the end.
- If the audio is not ready when a chapter ends, the next chapter starts in direct speech, as it already did when a render was late.

### Library and feeds
- A feed episode you mark played, with Mark Played or Mark All Played, now leaves the Reading List when "Remove books when finished" is checked, as a finished book does.
- If a window is reading it from the list, it leaves when that window goes on or closes. Mark Unplayed lets one still waiting to leave stay, and puts none back.
- Retry on a feed's unsaved changes, pressed while TextMouth moves its data directory, rebuilds it, or moves books between folders, no longer risks hanging TextMouth or writing into the folder being copied.
- The row says when the changes will be saved, for example "TextMouth saves them once the move of its data directory ends.", TextMouth saves them itself when that ends, and VoiceOver says "Feed subscriptions saved."

- From this version on, TextMouth keeps the keys a later TextMouth adds to a book's row, its record, config.json, library.json, and reading_stats.json when it saves them, so going back to this version and forward again loses nothing.

- Quitting waits up to 10 seconds for queued changes to your feed subscriptions to be written, and says "saving the changes to your feed subscriptions"; a change it gives up on is named in the unsaved-changes prompt.
- Retry and the saves of statistics, settings, and rules, pressed or due during a data-directory move, a folder edit, or Rebuild Directory, now wait for it and save when it ends, instead of writing into the folder being copied and calling it saved.
- Return on a feed's episode that is not downloaded now does what VoiceOver-Space does: it downloads the episode and opens it, where it opened the last downloaded episode before. Command-Delete on such a row no longer reaches the nearest book.

### Faster
- Text books are read faster: reading a chapter's Markdown takes 46% to 89% less time, and exporting a book as text 47% to 79% less. Every book reads and exports as before.
- TextMouth reads Markdown with swift-cmark alone and no longer includes swift-markdown, which saves 0.45 MB. This version's new formats take more than that back: the app is 18.5 MB, about 0.26 MB larger than 0.4.11.
- The licences of ZIPFoundation, swift-cmark, and the TTA, WavPack, and Monkey's Audio decoders TextMouth's own readers follow are now in both apps with the others.

### Caution
- TextMouth 0.2.1 to 0.4.11 open a library holding a picture or comic book without that book.
  The book's row and files stay, and 0.5.0 shows it again.

### Not changed
- How any book reads or is laid out.

## 0.4.11 (November 15, 2026)

### Smaller and faster
- TextMouth now builds its own copy of SwiftSoup, the library that reads HTML, leaving out the parts it never uses: that saves about 0.4 MB, and HTML is read about 40% faster, which shortens adding an EPUB, HTML, or Kindle book.
- Adding a book is faster: about a quarter faster for RTF, Word, EPUB, and Markdown books, and about 40% for plain text, and a book of thousands of chapters takes far less memory while it is read in.
- The licence of SwiftSoup is now in the app with the others.

### Cloud library
- A book opened on a Mac that is behind keeps the later place, with its bookmarks and settings, when another Mac saved a later place in the cloud.
- Closing a second window of a book you haven't moved in no longer puts an older place back.
- When a library's index or identity file hasn't arrived from the sync service, TextMouth waits for it, then shows Library Not Available with your choices: Open Without the Index…, Restore Its Identity…, or Give It a New Identity…. Each asks first, and nothing is opened as a new library on its own.
- Statistics and settings files that haven't arrived are no longer written over by this Mac's.
- A book you moved to the library with Move to Library… stays there when another Mac's out-of-date feed still lists it.
- Storage settings has a new button, Compare Libraries…. It lists what differs between this library and another copy of it, such as newer places, bookmarks, books, the reading list, and folders, and changes nothing.
- Use This Library now says which copy of the library is newer, and what only each holds, instead of "may not have its latest changes". While it compares, which can take up to a minute, Stop Comparing skips it.
- When a sync service sets aside a conflicting copy of a library file, a feed's record or index, or a book's record, TextMouth tells you once, in an alert, and leaves the copy where it is.
- Remove Download is stricter: it refuses a book unless the sync service says its upload finished and the copy on this Mac is the latest. If your drive never says so, the refusal tells you to free the space with the drive's own command, and nothing is deleted.

### Not changed
- How any book reads: the new copy reads every test document exactly as the old library did.

## 0.4.10 (November 14, 2026)

### Braille books whose code TextMouth guesses
- When you add a BRF or BRL file and your Braille Code is contracted Unified English Braille, TextMouth checks whether the book is plainly written in English Braille, American Edition, the code before UEB. If it is, the book is read with that code, so "to the sea" no longer reads "!the sea".
- Book Information then names the code with ", guessed" after it, followed by a note on how to correct it and a Keep This Code button. Choosing a code in the Braille Code pop-up replaces the guess.
- The Braille tab has a switch, "Guess the braille code of new books", on by default. Books already in your library are not changed, and PEF files are never guessed.
- Replace Existing keeps what Book Information says about a book's braille code: a guess you kept stays yours, and a guess stays marked as guessed.

### Smaller
- The app is about 1.3 MB smaller: its lists are sorted by one shared helper, and each book's details are kept once in memory and shared until one copy changes. Every list keeps its order, and your library's files are written exactly as before.

### Not changed
- How any book already in your library reads, sounds, or is laid out.

## 0.4.9 (November 14, 2026)

### Braille
- A BRF's running heads that differ only by a part or volume number, as "Life of Pi. Part 1" and "Life of Pi. Part 2" do, are left out of the text too.
- Book Information says the suggestion to choose English Braille, American Edition aloud once, when it appears.
- Every braille book is read again once more at the first launch of this version, and your place follows its words.

### The Reading List in a cloud library
- Books whose size the cloud doesn't report download one at a time, and TextMouth checks the free space again before each.
- Books still waiting stop downloading if you clear Keep these books on this Mac, stop keeping a book, or take it off the list.
- When the rest of the list turns out not to fit, VoiceOver says once how many reading list books there isn't room for, and the debug log names each book left out.
- The Remove books when finished hint now says a finished book leaves the list once its reader window moves on or closes, and the notice for one book names the list: "Downloading Moby-Dick, a reading list book".

### Speech
- Preparing the next chapter's speech ahead of time no longer sets up a second audio engine.
- Play after Stop on the same text, in the same voice, keeps the speech already prepared instead of preparing it again. What you hear, and where it starts, are unchanged.

### Not changed
- How any book other than a braille book reads, sounds, or is laid out.

## 0.4.8 (November 14, 2026)

### Braille books in English Braille, American Edition
- A book in English Braille, American Edition, read with that Braille Code, now reads "of the", "and the", "for the", and "with a" as separate words, and reads "moving-in", initials such as "p. b. u. h.", St. and Still, and "befuddled" correctly.
- Initials now read with spaces, so "e.g." reads "e. g.", and a search for "e.g." won't find it.
- A micro sign before a unit, as in "5 µm" or "µg/mL", stays µ. In contracted English Braille, American Edition, an italic word that begins with m is read as italic.
- Book Information says "This braille looks like English Braille, American Edition. Choose its Braille Code in Book Information." under Braille Code when a book read as Unified English Braille shows that older code's signs. TextMouth never changes the code by itself.

### BRF and BRL books
- A BRF's running heads, the line at the top of each page with the book's title and a page number, are left out of the text, and so are print page change lines, Roman ones such as ix among them.
- A centered chapter line that runs straight into an indented paragraph is now a heading, so a book's chapters can be reached with the headings rotor and Go to Heading.
- A BRF's title and author are read from its braille title page, so a Bookshare file named with a number shows its real title and author. A title or author you have typed in Book Information is never replaced.
- Every braille book is read again once at the first launch of this version, and your place follows its words.

### The reader window
- The reader window redraws only when something it shows changes, where before it redrew several times a second while a book played.
- Each sleep timer countdown, in the reader's status row and its playback bar, is drawn by a label of its own, and still changes every second, playing or paused.

### Using less of the Mac
- The Library's time remaining is added up once for each change, not again for every book each second.
- Timers that nobody hears may fire a little late, so macOS can combine their wake-ups. The sleep timer's countdown stays exact.
- While speech plays, the spoken position is updated only when it moves.

### Not changed
- How any book other than a braille book reads, sounds, or is laid out.

## 0.4.7 (November 13, 2026)

### The sleep timer
- Each reader window has a sleep timer of its own. A book opened in another window no longer shows a timer it can't run, which is how a timer could seem stuck while you listened to the next book.
- A window that goes on to another book in place keeps its timer counting; when the next book opens in a new window, that window takes the timer once its book has loaded.
- Closing a window stops only its own timer. Restart Sleep Timer acts in the window in front, and the headphones' or keyboard's restart gesture acts on the book you're hearing. Two windows' Sleep Timer sheets can be open at once.

### Search Library
- Edit > Find > Search Library… (Option-Command-F) searches the text of every book in the library at once, with Match Case and regular expressions, and opens a match in its book at those words (see [Search Library](search-library.md)).
- With the search texts made, a plain search of a library of 750 books takes about a second.
- TextMouth makes the search texts in the background after the first launch of each new installation, and a search made before then says "Preparing 120 of 737 books…" and takes several seconds.
- Search in Book has a Match Case checkbox, unchecked unless you check it.

### The Reading List
- Remove books when finished, a new option in the Reading List's options bar, takes a book off the list once you have finished it, and is unchecked unless you check it.
- A finished book stays on the list while its window rests on it, so Rewind, Play, and Next in Reading List still follow the list, and it leaves when that window goes on to another book or closes.
- In a library in the cloud, Keep these books on this Mac, checked unless you clear it, keeps every book on the Reading List downloaded, as Keep on This Mac does, and downloads only the books that fit in the free space, leaving 1 GB free.
- Remove Download and Stop Keeping on This Mac say when the Reading List keeps a book, and what lets it go.
- The Reading List's options bar goes on to a second line in a narrow window instead of cutting a label.

### Leading articles
- Settings > Library > Titles has a Leading articles pop-up: Part of the Title, as before and the default; Ignored When Typing; and Ignored When Typing and Sorting, which files The Hobbit among the H's and shows it as "Hobbit, The" in every Library list, feed, and the Books rotor.
- In the two new choices, typing a title's first letters passes over its article, so H reaches The Hobbit; typing the same letter again goes on to the next title with it, as the Library always has; letters typed into the search field stay there.
- A book whose details name French, German, Spanish, Italian, Portuguese, Dutch, Catalan, Swedish, Danish, or Norwegian passes over that language's articles too, and English "The"; folder names and a book's own title elsewhere (Book Information, the reader, Now Playing, export) are as written.

### Replace Existing
- Replace Existing no longer freezes TextMouth while it reads a long braille book again: the sheet dims its buttons, shows "Replacing “Title”. This can take a moment.", and VoiceOver hears it if the work lasts more than a second.
- Replace Existing keeps a text encoding you chose in Book Information, when the new copy is the same file or a file that names no encoding of its own and reads in your choice.
- Replace Existing keeps a braille book's braille code, as it kept its braille file characters, and both together when both differ.
- When a book is being replaced or read again with another braille code, what has to wait says so in a sentence of its own.

### Book Information
- A braille book's Braille Code is a pop-up button that reads the book again with another braille code, asking first, as the Text Encoding and Braille File Characters pop-ups do. An open reader follows the new code.
- The Text Encoding pop-up also offers CP437 (US DOS), CP850 (Western European DOS), and Mac Central European. TextMouth takes them for a new file only when macOS's own guess names one, so no book you have is read differently.
- Book Information for an audiobook stops waiting for the file's tags after 30 seconds and shows the details TextMouth keeps instead, where before a file that hung the system's audio reader left the sheet loading for good.
- Saving in any metadata editor removes the spaces and line breaks around each value, so "Press " is saved as "Press" and spaces typed over an empty field change nothing.

### Importing
- A PDF locked by a password is refused with "This PDF needs a password to open." in place of a message about text recognition.
- A Word document with no text is refused with "This file has no text to read.", where it used to import as an empty book.
- A ZIP batch's alert is titled by what the batch did: Nothing Imported, Already in Library, Some Files Not Imported, Book Imported, or Books Imported, never Error over books that came in.
- A folder of tracks or a playlist too big for the disk is refused before any track is copied, with "There isn’t enough free space on the disk.", and a track on the library's own disk counts as taking no room, since the copy shares its bytes.
- Saving an EPUB's details works when the book's container file spells the package document's path in another case than the archive does.
- A Markdown file whose block quotes and lists nest more than 128 levels deep is refused with a sentence, where it could once overflow TextMouth's stack.
- A DAISY 3 book of several DTBook files is read in one order every time, and numbers a page that holds no words through the whole book, 1, 2, 3, 4, where each file began again at 1.
- Every DAISY book is read again once at the first launch of this version, and your place follows its words; only a DAISY 3 book of several DTBook files can end with another text: its pages numbered through the whole book, and its files in their true order.
- A DAISY book's audio times written with a unit, as "500ms", "2min", or "1h", read as the time they name, for a book imported again.
- A web page named .doc, a web archive, and SSML read without pages when pages are not wanted, as they did before pages existed. Nothing you have is read differently.
- An OPML export no longer writes an apostrophe as &apos;, and the feed, OPML, and SSML code share one escaper for text in XML.

### Finder and size
- Finder offers TextMouth in the Open With menu for .mp4, .m4v, and .mov files, and never as the default app. TextMouth plays their sound.
- TextMouth's app is about 4 MB smaller, 19.5 MB where it was 23.5 MB, because it is compiled for size (with Search Library, Leading articles, and the rest of this version in it).
  HTML in an EPUB is read about 4 milliseconds slower for each megabyte at import, and nothing else you can notice changed.

### Not changed
- How any book other than a DAISY book reads, sounds, or is laid out.

## 0.4.6 (November 11, 2026)
### The End of heading timer on a book's cover
- A sleep timer set to End of heading on a book that opens at its cover, as a new Project Gutenberg EPUB does, no longer stops playback at once.
  - Before, the cover has no words, so Play started at the chapter after it. The timer had taken that chapter's first heading as the one to stop at, so it ran out as soon as reading began and said "Sleep timer expired at the end of the heading" before a word was read.
  - Now the timer stops where the heading that playback starts in ends, as the reader's description of End of heading says.
    The same goes wherever Play starts past the cursor: the blank lines that end a chapter, a section you skip, empty chapters, white space before a heading, and a long chapter whose speech Play waits for.
- Not changed: a timer set while playing, at a heading's start, or in the last heading; an audiobook's timer; how any book reads.

## 0.4.5 (November 10, 2026)
### Less waiting behind the Mac's slow parts
- Cancel is now heard at once while TextMouth checks the markup of a large Word, OpenDocument, Word 2003 XML, DAISY, or SSML file before reading it. Before, that check ran to its end first, which for a very large file took a few seconds.
- When macOS is slow to list its speech voices, the rest of TextMouth no longer waits behind it.
  - The list is now fetched on a thread of its own. After 10 seconds with no answer, TextMouth stops waiting for it, and asks again the next time you open something that offers voices.
  - Before, a listing that never came back held one of the few threads that TextMouth's background work shares, for good. Enough of them (three, on a Mac with three cores) stalled downloads, opening books, and the rest of that work until you quit.
- When TextMouth checks that an audio file's sound can be decoded, as it does when it reads an audiobook's files, the check no longer holds up other work.
  - If the check has not finished after 60 seconds, TextMouth stops it and uses the length the file's header gives.
  - Before, a check that never finished held one of those shared threads for good, and whatever waited for it never went on.
- Not changed: how any book reads, sounds, or is laid out.

## 0.4.4 (November 10, 2026)
### Quitting while work is under way
- The hang after Quit Anyway, or after a save, is gone.
  While feed downloads, a book's text read again in another encoding, or a speech export were under way, choosing Quit Anyway in the alert about unsaved changes, or answering the Record window's question or an audio editor's Save or Discard, could leave TextMouth open with its windows stuck.
  Now the quit ends.
- A second Command-Q, or the Dock's Quit, while TextMouth finishes that work no longer cuts it off. It used to quit at once, with a download's place not kept and a re-read or an export cut short.
- TextMouth now says what it is doing when you quit during that work, in a small window titled "Quitting TextMouth" and through VoiceOver:
  - "TextMouth is finishing up before it quits: WHAT. It will quit as soon as that is done."
  - What it says for downloads is "keeping the place of your feed downloads for next time". For a re-read it is "reading a book's text again in another encoding", and for an export "stopping a speech export with the chapters it finished kept".
    When several run, the sentence counts them, as in "reading the text of 3 books again in another encoding".
  - Pressing Command-Q again says the same words again.
  - The window does not take the keyboard from the window you were in.
  - The waits are the same as before: 3 seconds for downloads, 10 for a re-read, and 5 for an export. Work that cannot end gives up after its wait.
- Log out, restart, and shut down wait for the same work as before and are not cancelled by it. If you log out while TextMouth is finishing for your Quit, the log out goes on when the work has ended.
- The alert about unsaved changes is not shown a second time when you chose Quit Anyway and TextMouth had to finish work first.
- Not changed: a log out, restart, or shut down is still stopped by an alert about unsaved changes, or by a question from an audio editor, the Record window, or a library move.
- A limit: if a question stops the quit after the downloads have stopped (Cancel in the unsaved-changes alert, say), TextMouth stays open and the downloads stay stopped for the rest of that session. They are asked for again at the next launch.
- Not tried: a real log out or shut down. It was tested with the quit message the system sends, but not by logging out. Whether VoiceOver speaks the window's words when TextMouth is not the front app, as when you choose Quit in the Dock from another app, was not checked either.

## 0.4.3 (November 9, 2026)
### Kindle books: chapters at the licence, and no soft hyphens
- A Kindle book from Project Gutenberg now ends its last chapter where the author did. The licence's opening words, which used to sit at the end of the last chapter, now open the licence's own chapter, as in the EPUB of the same book.
  - Pride and Prejudice's last chapter went from 1,461 words to 1,248, and its licence from 2,694 words to 2,907.
  - Moby Dick's Epilogue went from 482 words to 267, and The Yellow Wallpaper's last chapter from 6,295 to 6,082.
  - The words of each book are the same, only the cut between chapters moved.
- A Modest Proposal in KF8 now has the 3 chapters of its EPUB: Project Gutenberg's header page, the essay, and the licence. It was 2, with the essay joined to the header page.
- Soft hyphens, the invisible marks a publisher puts inside words to say where a line may break, were already left out of KF8 books. Now they are left out of MOBI 6 books too: in the words, in the contents' names, and in a book of plain text.
  - Search in Book now finds a word that had one inside it. Before, a search for "hyphenation" did not find the same word with a soft hyphen after its "hy".
  - A braille display no longer shows a hyphen in the middle of such a word.
  - Speech no longer stumbles over one: the voice read a soft hyphen as if it were a hyphen, which made the word 2% to 6% longer to say.
- Not changed: an EPUB keeps its soft hyphens, which do the same there. No EPUB in the test collection holds one.

### Text files in more encodings
- A plain text, Markdown, or HTML file that is UTF-16 or UTF-32 and has no byte-order mark is now found in more cases, and read right instead of as garbage (see [What TextMouth reads](reads-text-files.md)).
  - Found: UTF-32 in either byte order, and UTF-16 in Greek, Cyrillic, Armenian, Hebrew, Arabic, Chinese, Japanese, or Korean. Before, only UTF-16 in Latin letters was found.
  - Book Information names the encoding it found, as in "UTF-16 (little-endian), recognized by its bytes".
  - A few stray zero bytes in a UTF-8 or 8-bit file do not make it UTF-16. In testing, 89 text samples and the same sentences in more than 20 encodings were read as before.
- Not found, and read with the wrong letters: UTF-16 in the scripts of India, and short Chinese, Japanese, or Korean UTF-16 with fewer than 8 spaces, digits, or line ends. A Chinese file needed about 46 characters and a Korean one about 28.
  UTF-16 and UTF-32 have no item in the Text Encoding pop-up, so save such a file as UTF-8, or with a byte-order mark, and add it again.
- An HTML file that declares ISO-2022-JP, a Japanese 7-bit encoding, and holds its escape codes is read in it. It was read as UTF-8.
- A subtitle file (.srt or .vtt) or an .m3u playlist in UTF-16 or UTF-32 without a mark, in a script other than Latin letters, is read right too.
- A book that recorded its encoding when you added it keeps it. Your own choice in Text Encoding still overrules everything.

### A folder that is a link, and clearer messages
- A folder that is a link to another folder imports as the folder it leads to, since you named it, and the book takes the name of that folder.
  A link to a folder of DAISY books in folders is refused, as the folder itself is, and a link to nothing is still an error (see [Adding books](adding-books.md)).
- Moving the library's folder, with a book stored outside the data directory, no longer says that the copy is missing the book's content.
  It says where the book is, that it is outside the data directory, and what to do: import it again and choose Replace Existing, or remove it from the library (see [Where TextMouth keeps your library](where-your-library-lives.md)).
- A Word document or DAISY book with a damaged ZIP part now says "The file “word/document.xml” in this document is damaged or incomplete: its compressed data could not be decoded. Get a fresh copy of the document, then import it again." It showed the ZIP library's own error.
  A full disk while a DAISY file is copied is still reported as a full disk.
- A Word document whose title is empty takes its file's name, and one whose creator is empty has the author "Unknown", as if it had none.
- A ZIP holding a DAISY book with audio is kept, and the "Book Imported" alert says why, even when a SMIL file in it has a tag with too many attributes for TextMouth to parse. Before, the archive could be offered for deletion although it held the only copy of the text.

### Transcripts
- Attach Transcript… reads a transcript for a book of more than 100 hours. Its times may run to 1,000 hours, and they are cut into the book's audio files.
  A single audio file is timed for only its first 100 hours: a passage that starts after a file's hundredth hour is left out and counted with the passages that could not be read, as in "2 timed passages couldn't be read and were left out." (see [Transcribing an audiobook](transcribing.md)).
- A passage of more than 10,000 characters is cut short at the end of a sentence, or between words, and Attach says so: "1 timed passage was too long and was cut short." A file that is one huge passage no longer makes one huge sentence in the book.
- A WebVTT or SubRip file chosen or opened together with its audio, with Open Book…, from Finder, or on the Dock icon, is attached to that audio's book, where it was refused as a book.
  A transcript file alone is still refused, and the refusal now says what to do: "Unsupported file format: .vtt. A .vtt file is a transcript, not a book. To use it, import its audio, open the book, and choose Attach Transcript… from the Book menu." (see [Adding books](adding-books.md)).
- Transcribe Audio… waits while a transcript is being attached to the book, whichever way it was asked for: "A transcript is being attached to Moby-Dick. Transcribe it once that finishes."
- Book Information names every format of a transcript found at import in files of more than one, as in "Attached from WebVTT and SubRip files when the book was imported, on …".
- A podcast episode's chapters come back when you undo every edit of its audio and save. They are set aside when edits are saved, since the edited audio no longer fits them. After Start Over they do not come back (see [Editing audio](editing-audio.md)).
- Not fixed: quitting TextMouth while it fetches a podcast episode's transcript makes the next launch download the episode again.

### Older versions
- The first time this version opens, every .mobi book (.azw3, .azw, and .prc too) is read again once, for the chapters and soft hyphens above (page reader line 1.1.0). Your place follows its words.
- The first time this version opens, every plain text and HTML book is read again once, for the encodings above (page reader lines 1.0.1 and 1.0.4). Its text is the same unless its file is one the new rules read. EPUB books are not read again.
- Markdown books are read the new way when they are added, or when their text is built again.

## 0.4.2 (November 8, 2026)
### Export a text book as spoken audio
- A text book's Export dialog has a checkbox, "Text as spoken audio", that speaks the book with its voice into one audio file, M4B, M4A, or MP3, with a chapter at each heading (see [Exporting books](exporting-spoken-audio.md)).
- Its options are Format, From and To (the book's headings), Speed, and Pitch, which start at the book's own speed and pitch, and a line naming the voice and one about Apple's licence. They have no group of their own, so VoiceOver reaches them right after the checkbox.
- The dialog reads the book's headings only once spoken audio is checked, so it opens at once.
- An MP3 has chapters for its first 255 headings only. Past 255, a line after the Format pop-up says so and suggests M4B, and the end of the export says so too.
- A chapter the voice can't speak fails the export with a sentence saying so: "The voice made no sound for “Chapter 3”. Check that the book's voice speaks the book's language."
- Progress says which chapter is being spoken. Stop keeps the chapters already spoken, and exporting the same range at the same speed and pitch goes on from there, until TextMouth quits, a different export of spoken audio starts, or the book's voice, text, substitution rules, or pauses change.
- Quitting TextMouth during an export stops it as Stop does, waiting at most 5 seconds, then quits. The next launch clears the chapters it had spoken, as it clears all kept chapters.
- A Personal Voice, no voice, too little disk space, a second export at once, and a range with nothing to speak are each refused with a sentence saying why.
- Every kind of export now refuses the folder where TextMouth keeps spoken chapters: "Export can't write into the folder where TextMouth keeps spoken chapters, since TextMouth empties it. Choose another folder."
- A real voice (Samantha) was exported to an M4B, an M4A, and an MP3, each with three chapters.
- Caution: while a spoken-audio export runs, listening to a book in TextMouth hasn't been tested. If the reading jumps back to words it has already said, stop the export or pause the reading.
- Not done yet: time ranges, a selection, and WAV, AIFF, CAF, Apple Lossless, and FLAC. Kept chapters are not swept at launch on iOS.

### Transcripts that come with podcasts and audiobooks
- Book > Attach Transcript… gives an audiobook a transcript from a WebVTT (.vtt) or SubRip (.srt) file, on any macOS, with nothing transcribed. It asks first before replacing a transcript the book has, and says so if you edited or cleaned it up (see [Transcribing an audiobook](transcribing.md)).
- An audiobook imported with a .vtt or .srt file beside its audio, named as a track is with its extension changed (01.vtt beside 01.mp3), takes that file as the track's transcript, whether the book came as one file, a folder of tracks, a ZIP, or a playlist. No transcription is offered then.
  A file that can't be used is named once the import is done, and never fails it.
- A downloaded podcast episode brings its own transcript and chapters, for every feed (see [Podcasts and article feeds](feed-listening-and-settings.md)). The chapters become its headings when its audio has none.
- Downloading an episode again replaces its own transcript with the new one, unless you made, edited, or cleaned up the transcript.
- Book Information has a read-only Transcript detail that says where a transcript came from and when, as in "Attached from “lecture.vtt” on October 30, 2026."
- Transcribe Audio… is dimmed for a book while a transcript is being attached to it, and says "A transcript is being attached to Moby-Dick. Transcribe it once that finishes." from any other route.
- Export's Transcript checkbox has a "Convert transcript to" pop-up that adds WebVTT and SubRip captions, one file for the book, timed from the start of its audio. SubRip writes a few strings as character references so that they read back as written, and other players may show those as written.
- A Transcript item that holds no timed transcript can't be written as captions, and the export says so: "The book has no timed transcript to write as captions."
- Replace Existing keeps a transcript that recognition made, or that you edited or cleaned up, over the transcript file the new copy brought. An untouched transcript from outside, attached or a podcast's, gives way to the file.
  The duplicate question says which will happen, and afterwards VoiceOver names a file that wasn't used and points to Attach Transcript… (see [Adding books](duplicate-books.md)).
- Fixed in the same work:
  - a speaker was misnamed after a cue that changes voice partway;
  - a 20 MB file of blank lines took 640 MB and now takes 80 MB;
  - SubRip writing lost cues on re-read;
  - a window closing during the Replace confirmation left Attach Transcript… dimmed until quit;
  - two tracks with the same name, such as 01.mp3 and 01.flac, both took 01.vtt;
  - Attach reads only a plain file, so a named pipe can't hang it;
  - and a chapter title is cut to 200 characters.

### Symbols in Word documents
- A Word document (.docx) and Word 2003 XML now read symbols, as .doc has since 0.4.1: a w:sym is read by its font, and text typed in a symbol font is read the same way (see [What TextMouth reads](what-textmouth-reads.md)).
- A check box in Wingdings, a font of pictures, reads as a space, where the words either side ran together. A bullet typed in Symbol reads as a bullet, and a greater-or-equal sign as itself.
- Of 2,244 real files compared before and after, 9 read differently and 2,235 the same. No real Word 2003 XML file holds a symbol, so that half is proved by tests alone.
- Not read: a font a table style names, a font a theme names alone, and the complex-script and East Asian fonts.

### Kindle books in the KF8 format
- An .azw3 book now imports, with its chapters, its headings at the levels its author gave them, and its print pages when it has page breaks (see [What TextMouth reads](reads-kindle-books.md)). A KF8 book named .mobi or .azw imports too.
  Earlier versions refused them with "This Kindle book is in the newer KF8 format, which TextMouth can't read yet."
- A .mobi file that holds a book twice, in MOBI 6 and in KF8, is read from its KF8 half. When the KF8 half can't be read, it is read from its MOBI 6 half.
- A copy-protected book is still refused, in either half of such a file: "This Kindle book is copy-protected, and TextMouth can't read copy-protected books." TextMouth never tries to remove copy protection.
- A book's contents decides its chapters: an entry that names a whole page titles that chapter, and an entry inside a page is a heading there.
- A piece of a book that opens with no heading of its own, and that no entry of the contents names, joins the chapter before it only when its title repeats the previous piece's, or is the heading the next piece opens with.
  This puts back together the chapters that calibre cuts into pieces: Pride and Prejudice no longer has the end of a chapter headed with the next chapter's name, and the Project Gutenberg licence is one section.
- A page of links that a converter added to the end of a book, headed "Table of Contents", is left out, so it is not read aloud at the end. Soft hyphens are left out.
- KF8 keeps no page list, so its pages are the page breaks in its text, when it has them.
- A book whose file is damaged says so: "This Kindle book is damaged or incomplete: …"

### A book nested deeply can no longer crash TextMouth
- A book or page nested however deeply can no longer crash TextMouth. The markup guard now parses, checks, and releases a tree on a thread with a 490 MiB stack, which holds a million levels, where the import's own stack held about a thousand.
- It costs about 55 microseconds a chapter. A 300-chapter book takes about 7 ms more.
- Untested on an iPhone: if the system refuses that stack, the guard falls back to 122 MiB, then 30 MiB, then the thread it was called from.

### Older versions
- The first time this version opens, every .docx and .wordml book is read again once, for the symbols it now reads (page reader line 1.3.0). Your place follows its words, and a book whose text you changed with Edit Text keeps that text.
- The first time this version opens, every .mobi book is read again once, for the KF8 half of a book that holds both formats (page reader line 1.0.0). Your place follows its words.

## 0.4.1 (November 7, 2026)
### Commands that said nothing now say what happened
- Move Book Up and Move Book Down (Library menu) now say why when they can't move a book, where they used to say nothing.
  In a folder in Folders that is not sorted by Manual Order: "Books can be moved only in a folder sorted by Manual Order, and this folder is not. Choose Manual Order in the Sort menu, then try again."
  In any other view, which mixes the books of many folders and has no order you arrange: "Books can't be moved in this view. Go to a folder in Folders, or to the Reading List, then try again." With no book selected: "No book is selected. Select the book to move, then try again."
  With several: "Several books are selected, and a move shifts one book at a time. Select just one book, then try again." A book already at the top or the bottom says "Dune can't move up." (see [The Library window](library-window.md)).
- A feed's episode or article in a folder in manual order can't be moved, and Move Book Up and Move Book Down say so: "TITLE is an item of a feed, and a feed's items can't be moved." In the Reading List an episode or article moves like any book.
- Move Book Up and Move Book Down are dimmed in a window that is not a Library window, where nothing would answer them.
- When a bookmark can't be added or removed because the book has left the library, the reader says so: "Could not add the bookmark: “Moby-Dick” is no longer in the library." or "Could not remove the bookmark: “Moby-Dick” is no longer in the library."
  It waits until focus has settled, so the sentence is not cut off. Before, Add Bookmark said "Bookmark 0 added" and Toggle Bookmark said a bookmark was removed.
- "Bookmark 4 added" now names the new bookmark's own number, the number its row in Show Bookmarks has, where it said how many bookmarks the book had (see [Reader windows](reader-windows.md)).
- Save in the metadata editor of an EPUB or an audiobook refuses a title you emptied, stays open with your edits, and says "Could not save: the book's title is empty. Type a title, then save again."
  A title of only spaces is never saved, by any editor, and a book that opened with no title is not held back from saving its other details.
- Writing an EPUB's details into the library's copy of its file, when that file is missing from the library, says so, where it said "could not be opened as a ZIP archive": "Could not save metadata to the library's copy of “alice.epub”, because that file is missing from the library.
  Turn off “Also write to the library's copy of the EPUB file” to save the metadata to the library only. Nothing was changed."
- New Book from Text now says when something did not work, in a sentence beside the buttons that VoiceOver also says once (see [Adding books](adding-books.md)):
  - Paste from Clipboard with no text on the clipboard: "The clipboard has no text to paste, so the text is unchanged. Copy some text, then paste again."
  - Open in Editor when its file can't be written, or when no app opens it: "Could not open the text in an editor, because its file could not be written. Paste or type the text here instead, or try again." or "Could not open the text in an editor, because no app opened its file.
    Paste or type the text here instead, or try again."
  - Reload from Editor when the editor's file can't be read back: "Could not read the text back from the editor's file, so the text here is unchanged. Save the file in the editor, then choose Reload from Editor again, or choose Open in Editor to start again."
- Reload from Editor reads the file the way an import does: as UTF-8, or in the encoding a byte-order mark names, or in the encoding its bytes look like, such as Windows-1251 Russian or Shift JIS Japanese.
  Only when nothing can be trusted is it read as Windows-1252, and if the text holds characters beyond ASCII, TextMouth says "The text was reloaded, but the editor's file does not say what encoding it is in, so some characters may be wrong.
  Check the text, or save the file in the editor as UTF-8 and choose Reload from Editor again." The note shows only until you change the text.
- A book made from text with a title of only spaces is called Untitled, and so is its file.

### A link in an audiobook's folder
- A symbolic link in an audiobook's folder no longer hides tracks. TextMouth skipped the folder listed right after a link, with every track in it, when it looked for a book's tracks, when it looked for a DAISY book inside a folder, and when it looked for a book's files that are only in the cloud.
  Only Finder's `__MACOSX` folder is skipped now.
- A book that lost tracks this way gets them back when TextMouth lists its folder's tracks again, which happens when the book's chapter index is rebuilt. Its tracks then come in a different order, so a saved reading position or bookmark in that book can land in another track.
  Nobody has looked in a library for a book this affects.

### Files built to stall an import
- A Word, EPUB, DAISY, SSML, OpenDocument text, Word 2003 XML, or PEF file can hold one start tag with thousands of attributes, which takes the system's XML reader longer the more it holds, minutes for a tag of 200,000.
  TextMouth now refuses a tag with more than 1,024 attributes, 27 times the most any real file in its collection has, before reading it, as damaged: "The file “word/document.xml” in this document is damaged or incomplete: it has a tag with too many attributes for TextMouth to read safely.
  Get a fresh copy of the document, then import it again." An EPUB says "this EPUB book", a DAISY book "this DAISY book", and an SSML file "This SSML file is damaged or incomplete: it has a tag with too many attributes for TextMouth to read safely." See [Adding books](import-progress-and-errors.md).
- The limit on the length of a start tag, one million bytes in OpenDocument text and Word 2003 XML, is gone, since the length of a tag costs nothing: only its attributes do.
  A Word document that holds a picture's data in one very long attribute (`o:gfxdata`, 267 KB in a government form) reads, and so do the words after a picture whose data passes 10 MB once encoded (a photo of about 7.5 MB), which the system's XML reader stopped at, losing every word after it.
- A Word, EPUB, DAISY, or SSML file whose document type declaration defines entities of its own is refused, where only the declaration's presence was a problem for OpenDocument text and Word 2003 XML before:
  - "TextMouth can't safely read the file “word/document.xml” in this document, because it defines entities of its own. Open the document in the program that made it, save it again, then import it again."
- An SSML file's sentence ends "Open it in a text editor, take the entity definitions out, save it, then import it again." A name of an external document type, as DAISY and NCX files give, is still read.
- A file in an encoding TextMouth can't read safely is refused in the same way, for UTF-7, the ISO-2022 family, HZ, EBCDIC, and any other name that is not on a list of the encodings it can:
  - "TextMouth can't safely read the file “word/document.xml” in this document, because it is written in the UTF-7 encoding. Save it as UTF-8, then import it again."
- UTF-8, UTF-16, UTF-32, US-ASCII, ISO-8859, Windows-1250 to 1258, KOI8-R and KOI8-U, Macintosh, Shift_JIS, EUC-JP, EUC-KR, GB2312, GBK, GB18030, and Big5 are allowed, with their usual aliases, in any capitals. Every real file in TextMouth's collection is in one of them.
- A feed or an OPML file gets the check for too many attributes and for an unsafe encoding, and not the one for entities, since old feeds declare entities of their own and still read.
  Such a feed says what the feed reader says of any damaged feed: "The feed is damaged at line 1: it has a tag with too many attributes for TextMouth to read safely." See [Podcasts and article feeds](feeds.md).
- A DTBook, an HTML page, or a Word document with thousands of page markers after a long line imports in a fraction of a second.
  5,000 empty page anchors in an HTML page took 24 seconds and now take 0.1 second, and a DTBook with 5,000 page numbers after a long line took more than 150 seconds and now takes under half a second.
- Cancel in the import overlay is heard during a Word document's parse every 1,024 elements, where it was every 4,096.
- When these checks refuse a DAISY book's SMIL file while its archive is being looked through, the notice that the archive holds text the audiobook lacks is not shown for that book.

### Word documents' hidden text
- A Word document (.docx) now follows Word's own rule for hidden text. A table style that hides text, and document defaults that hide it, count, as do a paragraph style and a character style.
  A paragraph style and a table style reset the state to what they say, and a character style toggles it, so a hiding character style inside a hiding paragraph style shows the text, as in Word. This comes from Microsoft's and ECMA's documents, not from trying it in Word.
  Conditional formatting inside a table style (the first row, say) is not applied. Of 1,723 real Word documents compared before and after, the only one that reads differently is a test file from Apache POI that defines entities of its own, which is now refused.
- A row marked hidden no longer hides the words in it in Word 2003 XML, and a .docx reads such a row as before. Word shows a row that has any visible part, so the words in it are read unless their own formatting hides them, and a row that Word hides has hidden words in it already.

### Export a book as an EPUB
- Convert to, in the Export dialog, offers EPUB for a text book, after Word 97-2003 (.doc) and before BRF. Its hint is "An e-book with the book's headings, contents, and page numbers where it has them, for Apple Books and other reading apps. It holds no pictures."
  The file is named like the others, as in "Moby-Dick - Text.epub" (see [Exporting books](exporting-books.md)).
- The EPUB 3 file keeps what a reader who navigates by headings and pages needs:
  - a file for each chapter (a long chapter goes on in another file after about 256,000 bytes, at a heading where there is one),
  - real headings at their levels,
  - a contents list nested by those levels,
  - and, for a book with pages, a page list and a marker where each page begins.
- It says the book's language when the book has one,
  - marks a book written right to left, such as one in Hebrew or Arabic, as right to left (by its language, or by its script when the language tag names one: Arabic in Latin letters is not),
  - and guesses the direction of each block from its words when the book names no language.
- Its accessibility notes say only what is true of the file: that it is text only, whether it has real headings, and whether it has pages. Nothing is added to the words: a chapter with a title and no heading is named in the contents and gets no heading.
- It holds no pictures (their alternative text stays as text), styles, raw HTML, or cover, and a link only where the address is a web or mail address (http, https, or mailto), written so that an EPUB checker accepts it; any other link is plain text.
- TextMouth checks the file once it is written, by opening it again and reading every part of it back whole, and removes it if it does not:
  - a disk that fills at the last moment gives "The EPUB file could not be written, because the disk may be full.", or the system's own words for a read-only volume or a permission, and not a broken file reported as exported.
- EPUBCheck 5.2.1 found nothing to report in the exports of the 18 books TextMouth tests it on.
- Differences you can meet when TextMouth imports one of its own exports:
  - A heading made from a styled paragraph, which has an entry in the contents and no heading in the text, reads back at its depth in the contents, not at the level the paragraph had: levels 3 to 6 alone under a chapter read back as 2. Real headings keep their levels.
  - Such an entry in a table cell moves to just before the table, so its place reads back a few words early. A page that begins in a cell stays in the cell.
  - In a run of chapters that hold only page markers, the chapters' titles all point at one file, and the reader keeps only the first title: chapters A, B, C, and D read back as A.
  - A chapter that begins with words before any heading shows one more heading row at its start. A long book with no headings, which the export split into several files, shows a row named for the book and then rows named "Chapter 2", "Chapter 3", and so on, one for each file that continues it.
    The words and the pages are the same.
- An EPUB whose language is "und", which is how TextMouth's own export says a book names none, now shows no language when it is imported, where Book Info would have shown "und". Only a book imported from now on is affected: no book already in the library is read again for it.
- HTML export is changed for books that skip heading levels:
  - its contents list put two lists inside one item for them, which is not valid markup, and now has one list, with a heading that rises out of a skipped level beside its sibling (headings 1, 3, then 2 list the 3 and the 2 together under the 1).
- HTML and PEF files carry the book's language only when it is a well-formed language tag. Every export keeps the words that follow a page marker on the same line, which the walk of the text used to drop.

### Word 6 and Word 95 documents
- TextMouth reads Word 6 and Word 95 documents (.doc and .dot) with code of its own, on the Mac as on iPhone, where Apple's textutil does not exist.
  On the Mac, textutil read them before; now textutil is left only a Word document older than Word 6, and nothing else, and on iOS such a document is refused as before (see [What TextMouth reads](what-textmouth-reads.md) and [Adding books](import-progress-and-errors.md)).
  A Word 1 or Word 2 document is not a compound file and is refused at once, as before: "This file could not be read as a Word 97-2003 document. It may be damaged, or another kind of file."
- Headings are the document's own heading styles, where textutil lost them.
  A document that names its own headings keeps exactly those, and a document that names none still gets the guess from font sizes and bold, which finds fewer headings than textutil guessed in a few documents, mostly in table cells and list items, where TextMouth never guesses.
- Text is read in the code page of its run, not of the document alone: Macintosh text in a Windows document, and the reverse, and runs in a Cyrillic, Greek, or Central European font each in their own. Far East documents are read as double-byte text.
  Textutil read Russian as Western letters, and Korean and Chinese wrongly or not at all, in files this reader reads; it read one real file as nothing.
- Bold and italic are kept and their marks never spoken. Hidden text and tracked deletions are not read, a note is read only if its reference is shown, and footnotes, endnotes, and text boxes follow the text. Tables are tables.
  Pages are the document's page breaks and sections that start a page, but a continuous section break begins no page, where textutil began one.
- A paragraph that Word numbers or bullets is a real list item, with its number in the book's stored text and not read aloud. A numbering that a style carries is not followed, so a numbered heading reads without its number.
- Not read: headers, footers, comments, pictures, field instructions (only a field's result is), and text typed in Wingdings, which reads as the letters of its bytes.
- Word documents' pages and headings were read from textutil's output before. A few real documents read a little differently as a result: textutil wrote a no-break space for some spaces, upper-cased text that Word merely displayed in capitals, and joined table cells.

### Symbols in Word documents
- A symbol in a Word 97-2003 document, which the file stores as an opening parenthesis with the font and the code of the character it shows, used to read as "(". It now reads as the character, by its font:
  - Symbol, and its clones MT Symbol and SymbolPS: the Adobe Symbol encoding, so Greek letters, mathematical signs, and the bullet read as themselves.
  - WordPerfect's WP TypographicSymbols: the curly quotation marks (so "firm’s" is no longer "firm s"), the bullet, the section sign, the inverted question mark, and the em dash. WP MathA: the degree sign, the bullet, and the micro sign (so 100 micrometres is no longer "100 m").
    WP Greek Courier and Century: the micro sign.
  - A picture font (Wingdings, Webdings, Zapf Dingbats, Monotype Sorts, any other WordPerfect font, and any font of the symbol character set) reads as a space, so the words on either side do not run together. So does a code of a WordPerfect font that no real document settles.
  - An ordinary text font: the character of its own code page.
- Text typed in the Symbol font in a Word 97-2003 document, stored as a private-use character, is read as the Greek letter or sign, and in a picture font as a space.
  In an ordinary text font it is read through the Symbol table too, as textutil read it, so a letter that stands for mu or pi reads as mu or pi, and a checkbox set in Arial reads as the Greek letter theta.
- A bullet made by a symbol, at the start of a paragraph, now makes a list item. A paragraph that holds only a picture symbol, such as a checkbox, is no longer written.
- Word 6 and Word 95 documents read their symbols by the same rule, and read text typed in Symbol as its Greek letters or signs.

### Markup that could crash TextMouth
- A damaged or deliberately crafted book, web page, or feed can no longer crash TextMouth through its HTML reader, the one that reads EPUB chapters, HTML files, DAISY books, Kindle books, web archives, and the pages and titles of feeds.
- There were three ways it could, and each could come from one flipped byte or a file made on purpose:
  - A broken declaration, such as `<?a>` or a torn `<?xml version="1.0"`, stopped the reader.
  - Markup nested thousands of levels deep overflowed the stack of an import.
  - A document of millions of tags filled the Mac's memory, since each tag takes a kilobyte or two however few bytes it has.
- TextMouth now looks through the markup once before it reads it, and again at the tree it makes. A broken declaration is read as nothing, with the words around it, and no sentence is spoken.
- Markup that passes a limit is refused with a sentence that says what is wrong and what to do, and never calls the file damaged, since it may not be (see [Adding books](import-progress-and-errors.md)):
  - More than 128 levels deep: "This file's markup nests more than 128 levels deep, which TextMouth can't read safely. Get another copy of the file, or save it in another format, then import it again."
  - Too much markup in one document: "One document in this file holds too much markup for TextMouth to read without running out of memory. Divide the document into smaller files, then import them."
  - More than 1,000 attributes on one tag: "One tag in this file has more than 1,000 attributes, which TextMouth can't read safely. Get another copy of the file, or save it in another format, then import it again."
  - Markup built so that reading it would take far too long: "This file's markup is built in a way that would take TextMouth far too long to read. Get another copy of the file, or save it in another format, then import it again."
- A Kindle book whose markup nested more than 256 levels deep was refused as damaged, with "its markup is nested more than 256 levels deep". It now meets the first sentence above, at 128 levels.
- An EPUB with one refused chapter reads its other chapters, and the report of the book names the chapter that was left out. A feed gives no sentence: a page, an article, or a title that passes a limit is passed over.
- Every real book tried reads as before. Of 355 real files, among them the largest Project Gutenberg and Standard Ebooks offer, and 62 web pages and other files fetched for the test, every one reads exactly as it did, and none is refused.
- The deepest real file nests 12 levels and the deepest web page tried 36 (GitHub's), against a limit of 128. The biggest document, a whole dictionary as one 32 MB HTML file, uses under half the memory limit.
- No book is read again for this.

### Older versions
- The first time this version opens, every .doc book is read again once, for the Word 6 and Word 95 documents and the symbols it now reads (page reader line 1.3.0), and every .docx and .wordml book once, for the hidden text it now finds (1.2.0).
  Your place follows its words, and a book whose text you changed with Edit Text keeps that text.

## 0.4.0 (November 6, 2026)
### Kindle books in the KFX format
- TextMouth reads Kindle books in the KFX format that are not copy-protected: .kfx, .kfx-zip, and .azw8 files, and an .azw file that holds KFX, as Kindle's apps name their KFX books.
  Each becomes a text book like any other, shown in the Library window as Kindle Book (KFX), so it reopens, searches, and keeps its place, bookmarks, and skipped headings (see [What TextMouth reads](reads-kindle-books.md)).
- A book's chapters come from its own table of contents, and its headings keep the levels the book gives them. A book with a print page list has pages, so Page, Skip Forward, Skip Backward, and Go to Page… work as they do in an EPUB (see [Reader windows](reader-pages.md)).
  A page list that a machine made to approximate pages is not read as pages.
- A copy-protected book is refused, never read, and TextMouth never tries to remove the protection: "This Kindle book is copy-protected, and TextMouth can't read copy-protected books."
  A book with no flowing text, such as a fixed-layout book, a print replica, a comic, a magazine, a children's book, or a notebook, is refused with "This Kindle book has no flowing text to read, such as a comic or a print replica, so TextMouth can't read it."
  A Kindle Create package (.kpf) is refused with "This file is a Kindle Create package, which TextMouth can't read yet." [Adding books](import-progress-and-errors.md) gives every sentence.

### OpenDocument text and Word 2003 XML
- TextMouth reads OpenDocument text (.odt, .ott) and Word 2003 XML with code of its own, on the Mac as on iPhone, where Apple's textutil does not exist. On the Mac, textutil now reads only Word 6 and Word 95 documents, which iPhone still refuses.
- Headings are the document's own, where textutil lost them and guessed from font sizes. A document that names even one heading keeps exactly the ones it names, and a document that names none still gets the guess.
- Pages are found from the document's page breaks, the pages its styles and master pages begin, and, in OpenDocument text, the soft page breaks its program recorded.
- An .odt's author is read, where textutil lost it. A book added before this version keeps its author Unknown until you import the file again with Replace Existing (see [Adding books](import-progress-and-errors.md)).
- A picture, formula, or chart in an OpenDocument text is read as its description. Hidden text, tracked deletions, comments, headers, and footers are not read, and footnotes and endnotes follow the text.

### Every document reader reads the same
- Rich text, Word 97-2003, Word, OpenDocument text, and Word 2003 XML documents now follow one rule: TextMouth reads what a person reading the document sees in its ordinary view. Hidden text is not read, and text hidden only on the web is. A tracked deletion is not read and an insertion is.
  Text a tracked change moved is read once, in its new place. A field's code is never read, and its result is.
- Footnotes and endnotes follow the main text, in the order the file keeps them, with no reference marks (a Word 97-2003 document's custom mark, the symbol an author typed in place of a number, is still read). A note is read only if a person would see its reference.
  Comments, headers, and footers are not read.
- A text box is read right after the paragraph that holds its anchor, so a sentence stays whole. A Word 97-2003 document keeps its text boxes apart, and they follow its notes. A Word text box that the file writes twice is read once.
- Rich text: text a tracked change deleted is no longer read aloud, footnotes and endnotes are read after the text, and a list inside a table cell is a list in an export.
- Word documents: hidden text is no longer read, notes follow the text, and the marks of bold, italic, and strikethrough are never spoken. Some Word documents spoke an asterisk or a tilde where bold or italic text began or ended beside punctuation.
- Word 97-2003: hidden text and tracked deletions are left out, and the formatting a fast-saved document keeps is read. A paragraph that Word numbers or bullets through its own lists is a real list item, with its number in the book's stored text, so an export shows it.
  The number is not read aloud, and a numbered heading reads its words alone, as in every format. A note whose reference is hidden or deleted is left out, and a few documents that were refused are read.
- Cancel in the import overlay now stops the reading of a rich text, Word, OpenDocument text, or Word 2003 XML document, or a Kindle book, partway through it, where it waited for the whole document before. A Word 97-2003 document ends at the next step after it is read.

### Older versions
- Caution: TextMouth 0.2.1 to 0.3.2 opens a library that holds a KFX book without that book. The book stays in the library, so this version shows it again, but it leaves the Reading List the next time the list changes in the older version.
  TextMouth 0.2.0 and earlier can't open such a library at all.
- The first time this version opens, every rich text, rich text with attachments, Word 97-2003, Word, OpenDocument text, and Word 2003 XML book is read again once, for what the readers now find. Your place follows its words, and a book whose text you changed with Edit Text keeps that text.

## 0.3.2 (November 6, 2026)
### A library in the cloud
- A library in Google Drive, iCloud Drive, or Dropbox now opens by itself when some of its files aren't on this Mac. TextMouth gets them from the sync service, shows Getting Your Library while it does, and opens the library when they arrive.
  It used to stop on Library Not Available until you chose Try Again (see [Where TextMouth keeps your library](where-your-library-lives.md)).
- If it can't get them, TextMouth says so and says what to check, after trying again for a little while. Books you opened from Finder while waiting open with the library, or are named if they couldn't.
- TextMouth also gets your settings, statistics, substitutions, and feed records in the background when a library in the cloud opens, and never saves over a copy still in the cloud.
- TextMouth can no longer freeze at launch waiting for a folder that is only in the cloud.
### Commands
- The Next Page and Previous Page commands and their keys are gone. To move by page, choose Page as the navigation unit and use Skip Forward and Skip Backward, or use Go to Page… (Option-Command-G) (see [Reader windows](reader-pages.md)).
  A key you gave either of those commands is dropped the next time TextMouth opens, and your other shortcuts are kept.

## 0.3.1 (November 5, 2026)
### Rich text and Word documents
- TextMouth reads rich text (.rtf), rich text with attachments (.rtfd), and Word 97-2003 documents and templates (.doc, .dot) with code of its own, on the Mac as on iOS.
  Apple's textutil tool read them on the Mac before, and does not exist on iOS (see [What TextMouth reads](what-textmouth-reads.md)).
- A document's headings are the ones its author set: a paragraph in a heading style, or with an outline level, is a heading at that level, where textutil lost the styles and guessed from font sizes. A document that names no heading still gets the guess from font sizes and bold.
- Pages that textutil lost are found. In rich text, a paragraph set to start a page and a section that starts a page begin pages, as a page break does.
  In a Word 97-2003 document, a paragraph set to start a page, directly or by its style, and a section that starts a page begin pages, as the author's page breaks do (see [Reader windows](reader-pages.md)).
- A Word field's code, which textutil sometimes read aloud as words such as TITLE and MERGEFORMAT, is never read, only the field's result. A Word document's headers are no longer read at the end of the book.
  Text a tracked change deleted is left out, and the footnotes and endnotes follow the main text.
- Hidden text in a rich text document is not read, and neither are its headers, footers, and footnotes. The words in a drawing's text box are read.
- A rich text file that textutil refused as damaged, such as one that begins {\rtf with no version number, is read.
- Rich text in a code page of two-byte characters, such as Japanese, Chinese, or Korean, is read whole.
- An .rtfd package is held to the 64 MB limit by its text file, TXT.rtf, alone, and its attachments no longer count.
- Rich text, rich text with attachments, and Word 97-2003 documents read the same on iOS as on the Mac. OpenDocument text, Word 2003 XML, and Word 6 and Word 95 documents are still read by textutil on the Mac, and on iOS are refused (see [Adding books](import-progress-and-errors.md)).
- The first time this version opens, every rich text, rich text with attachments, and Word 97-2003 book is read again once, for its headings and its pages. Your place follows its words, and a book whose text you changed with Edit Text keeps that text.

## 0.3.0 (November 4, 2026)
### Kindle books
- TextMouth reads Kindle books that are not copy-protected, in the MOBI format: .mobi, .prc, and .azw files in the older MOBI 6 format, and the MOBI 6 part of a .mobi made for both formats, as many Kindle books are.
  Each becomes a text book like any other, so it reopens, searches, and keeps its place, bookmarks, and skipped headings (see [What TextMouth reads](reads-kindle-books.md)).
- A book's chapters come from its own table of contents, the entries under a chapter being its headings, and a book with no table of contents is a chapter for each page break its maker wrote. What a book's head says about it is never read aloud.
- Open Book… offers Kindle books, and Finder offers TextMouth in the Open With menu for them.
- A copy-protected book is refused, never read: "This Kindle book is copy-protected, and TextMouth can't read copy-protected books." A book only in the newer KF8 format, as an .azw3 is, is refused for now, with "This Kindle book is in the newer KF8 format, which TextMouth can't read yet."
  [Adding books](import-progress-and-errors.md) gives every sentence.
- Kindle books have no pages yet.

### Older versions
- Caution: TextMouth 0.2.1 to 0.2.6 opens a library that holds a Kindle book without that book. The book stays in the library, so this version shows it again, but it leaves the Reading List the next time the list changes in the older version.
  TextMouth 0.2.0 and earlier can't open such a library at all.

## 0.2.6 (November 4, 2026)
### Reading
- A book whose EPUB gives its pages no numbers no longer has a page named by its markup: a page list whose one entry was named "pagenum_000000" made the page button say "Page pagenum_000000 of 1".
  A page list that gives none of its pages a number now counts as none, and a page break named only "Page" is no page. Such a book shows no page button, and Next Page says "This book has no pages."
- The hint of Go to Page…'s field says how many pages the book has, from its first page to its last, as in "This book has 300 pages, from i to 300. Type a page as the book numbers it, such as 12 or xii." A book of one page names it: "This book's only page is 1."
- A page a book names "Page 12" is now page 12, where the page button said "Page Page 12 of 300".
- A book of one page shows no page button, which said "Page 1 of 1" wherever you were.
- In a book of one page, Next Page, Previous Page, Go to Page…, and a skip by Page say "This book has only one page." and do nothing. The Navigate menu dims the three commands, the playback bar's pickers leave Page out, and Where Am I? leaves the page out.
- The first time this version opens, every EPUB and HTML book is read again once, for its pages. In the books these changes mend, a page number printed at a page break now names its page, and is no longer read aloud, as page numbers never are.

## 0.2.5 (November 1, 2026)
### The next book in this window
- When listening goes on from one book to another, at the end of a book or with Next in Reading List and Previous in Reading List, the next book now shows in the window you are in, in place of the book there, instead of opening a new window.
  The window keeps its place and size on the screen, and the book you leave is saved as closing its window saves it (see [Reader windows](reader-book-end.md)).
- A book already open in another window comes forward, and the window you moved from closes, so no two windows show one book. A sheet or an alert open over the window, a field being typed in, Edit Text in use for the book, or a library that is moving or not available still opens a new window.
- The Playback tab of Settings has a pop-up button, "Open the next book in", with "This Window", the default, and "A New Window", which keeps the way earlier versions went. config.json holds it as nextBookWindow (see [Settings](settings.md) and [Editing settings in config.json](config-json.md)).
- Feed Info has a pop-up button of its own, "Open the next episode in", "Open the next article in", or "Open the next item in", and Folder Settings has "Open the next book in", each with "Use the global setting" first, then "This Window" and "A New Window".
  It is dimmed, with a hint that says when it is available, while the feed's or folder's items do not go on to another item when one ends (see [Podcasts and article feeds](feed-listening-and-settings.md) and [The Library window](library-window.md)).

### Next and Previous in a folder
- The Navigate menu has Next in Folder and Previous in Folder, in a reader window, with no keys until you give them some in the Shortcuts tab.
  They go to the next or the previous item of the book's folder or feed: Next goes the way the end of the book would go on, up in a feed or folder that plays the one above and down in every other case, and Previous goes the other way.
  A book that was playing plays the item, after "Starting: TITLE", and any other only opens it, after "Opening: TITLE".
- An episode that is not on this Mac is downloaded first, with "Downloading the next episode: TITLE" or "Downloading the previous episode: TITLE", and goes on when it arrives. With no item that way, they say why, as in "No more books in folder."
  A failed or cancelled download says so, as in "The previous episode could not be downloaded. REASON" and "Download of the previous episode cancelled."

### The sleep timer
- A running sleep timer now goes on with listening to the next book, in this window or a new one, and stops that book when it runs out, where before it kept the next book from starting, as in "Opening: Dune. Not started because of the sleep timer."
  Going on to another book never starts its countdown again, the timer waits for a book that is still opening, and a timer set for the end of the heading or of the book that runs out at a book's end still ends listening there.
- Restart Sleep Timer, from its shortcut or the AirPods gesture, while the timer is on its way to the next book, starts it again and it still goes on with the book.
- The timer can say two new sentences: "Sleep timer cancelled, because the next book could not be opened." when the book failed to open, and "Sleep timer cancelled, because you moved to another book while it faded out." when Next or Previous ended a fade.

### Older versions
- Caution: an older TextMouth ignores the new setting, opening every next book in a new window, and drops a feed's or folder's own choice the next time it saves that feed or folder.

## 0.2.4 (November 1, 2026)
### Library
- The Library window's View pop-up, which VoiceOver calls "Library view", replaces the row of categories, and offers the views you choose, in the order you choose: Folders, All Items, Unopened, Recently Opened, Reading List, Feeds, and views of your own (see [The Library window](library-window.md)).
- A new Feeds view lists the feeds alone, each by title, and the pop-up offers it only while there is a feed, until you set it to Always.
- The Library tab of Settings, between Stats and Feeds, lists the views in order, and sets each one to Always, When Applicable, or Hidden, with Move Up and Move Down (see [Settings](settings-library.md)).
- New View…, Edit…, Duplicate, Delete…, and Restore Default… make and change views, with what each lists, All Conditions or Any Condition, nine kinds of condition, one item for each feed, a sort, and a limit, and a count of what the draft lists.
  The built-in views are changed the same way, and Restore Default… gives one back.
- A view you hide, or that lists nothing, stays in a window that shows it until you choose another, and a view deleted while a window shows it moves that window to the first view offered and says so.
- Go to View 1 to Go to View 9, Command-1 to Command-9, go to the first nine views the pop-up offers, and say the view's name and what it lists; the Library menu has a Go to View submenu.
- The libraryViews key of config.json holds the views, and every view's sort stays in library.json (see [Editing settings in config.json](config-json.md)). A TextMouth older than 0.2.4 drops the key from config.json, but the Mac keeps the views.

### Braille
- A BRF or BRL file is read in the braille file characters it is written in: North American Braille ASCII, Eurobraille, six-dot (German-speaking countries), or Unicode braille patterns, which TextMouth recognizes by the file's bytes (see [What TextMouth reads](reads-daisy-and-braille.md)).
- The Braille tab has a "Braille file characters" pop-up for the books you add from then on, and the Export dialog has one for a BRF, which starts from it.
- Book Information has a "Braille File Characters" pop-up that reads a BRF or BRL book again in other characters, asking first, and Speak Full Info says "Braille characters: North American Braille ASCII".
- A file in eight-bit computer braille or in UTF-16 is refused by name, with a sentence that says so (see [Adding books](import-progress-and-errors.md)).
- Replace Existing keeps a braille book's characters.
- Stop in the Export dialog ends a braille export at once, even while its translation runs.
- Caution: a library holding books set to Eurobraille or Unicode braille patterns should not be opened in a TextMouth older than 0.2.4.
  An older TextMouth reads such a book as North American Braille ASCII when it reads its file again, which gives wrong numbers and punctuation, or refuses a Unicode book and keeps its old text.
  And it drops the setting at its next save (see [Where TextMouth keeps your library](book-packages.md)).

### Reading and playing
- Quitting while a book plays keeps its place to the second, not up to 30 seconds back, and a book at rest writes nothing at quit, so a Mac left idle never undoes another Mac's newer places in a shared library.
- The time the Mac sleeps with a book playing no longer counts as listening.
- A one-file audiobook with chapter markers plays its last seconds before it is announced finished.
- Next Bookmark and Previous Bookmark go in the order the bookmarks lie in the book.
- A sleep timer of minutes stops counting while nothing plays after a stop, as after a pause.
- Stop, or Release Media Controls, while a chapter downloads from the cloud no longer leaves Play doing nothing.
- A voice that reports a word past the end of its text no longer ends TextMouth.

### Podcasts and feeds
- Cancel Download chosen while the episode is already being added says "“Ep. 368” is already being added to the library.", and the episode stays as it was asked for.
- Download or Open chosen right after Cancel Download now downloads the episode.
- A feed download or check stopped just as it began no longer stays stuck until TextMouth restarts.
- An episode you deleted stays deleted when its feed briefly lists nothing, or less.
- New episodes a check found are not lost when the library could not be saved before quitting.

### Importing
- Open Book… opens a TextMouth package, a folder ending in .tmb, instead of refusing it, and puts it in the folder the window shows; of several chosen, only the first opens.
- A TextMouth package inside a ZIP imports as one book, with its places and bookmarks.
- Opening a copy of a book's package no longer points the book at the copy.
- A ZIP holding a DAISY book with audio is kept after import, since it can be the only copy of the book's text, and an alert says so.
- Delete After Import never deletes a file inside another book's package or inside the TextMouth library folder.
- A Markdown book whose file is named content.md keeps its own file.
- A duplicate's new copy left by quitting before its question was answered is moved to the Trash at the next launch, with an alert titled "Duplicate Copies Moved to the Trash" that says how to Put Back, unless its question is less than a day old.
- Keep Both and Replace Existing say, naming the book, when the library can't be reached, when the copy's files are gone, or when TextMouth could not keep the copy.
- An import from a disk or network share that drops partway reports the failure instead of ending TextMouth.
- An EPUB can no longer bring the text of a file on your Mac into its title, author, or headings.
- EPUB, DAISY, and PDF books whose contents, page list, or outline nest thousands of levels deep import without crashing.
- An audio file whose header claims an absurd length or sample rate is refused instead of ending the import.
- An Ogg file named .mp3 or .m4a is no longer opened by Apple's audio code during import.

### Your files
- Adding back a book removed with Remove from Library Only keeps your Edit Text changes, and a package of an edited book imports; text that could not be kept is saved beside the new reading as content.md.edited-, and a book that could not be kept stops being added back and says so.
- Reading positions saved while the library index could not be read are kept once it is restored.
- Rebuild Library Index no longer replaces an index that can be read again, and says "The library index was not rebuilt. It can be read again now. Choose Try Again to use it."
- A Reading List change made while a folder is renamed or moved, or the library is moved, is no longer undone.
- A library opened without its index keeps its folders, and a book in a folder with no row gets one at launch.
- A move of the data directory from a folder that is not there says "The current data directory does not exist."

### Audio editing
- The equalizer, and every filter, says which option it needs when it is given none, as in "The equalizer filter needs its frequency: give a number from 0.0001 to 999999.", and a width that makes no usable filter is refused, where it ruined the audio it was applied to.
- An exported MP3 chapter's title is no longer cut short at a Windows line break.

## 0.2.3 (October 25, 2026)
### Reading
- You can choose the encoding a plain text, Markdown, or HTML book's file is read in, which mends a guess that was wrong or missed, and the book is read again in it with its places moving to their words (see [The Library window](book-information.md)).
- Automatic, in the same choice, reads the file as TextMouth reads a file you add, which takes a choice back.
- A file is read in the encoding you choose whatever its bytes say of themselves, and one with a byte that is not valid in it is refused with "“Moby-Dick” can't be read as Shift JIS (Japanese): it holds bytes that are not valid in that encoding. Nothing was changed."
- Characters of JIS X 0212 in EUC-JP, the euro sign in Big5 and EUC-KR, and Big5-HKSCS characters are refused when you choose those encodings, since macOS reads them wrongly or not at all (see [What TextMouth reads](reads-text-files.md)).

### Library
- Book Information's Text Encoding is a pop-up button now, for every plain text, Markdown, or HTML book you added from a file, where it was a row only for a book whose encoding was guessed.
- The pop-up names the encoding the book is read in and what decided it, as in "Windows-1251 (Cyrillic), guessed", "Shift JIS (Japanese), chosen", "UTF-8, from its byte order mark", "ISO 8859-2 (Central European), declared in the file", or "Windows-1252 (Western European), the default".
- Choosing an encoding asks first, and says what happens to your place and bookmarks and to an edit of the book's text, which is kept beside the new reading as a copy.
- VoiceOver says what the book is now read as, as in "“Moby-Dick” is now read as KOI8-R (Russian), chosen.", and where a copy of its earlier text was kept.
- Speak Full Info says "Text encoding: Shift JIS (Japanese), chosen." for a book whose encoding you chose.
- A book is not read again in another encoding, and the sheet says why, while the library's text is being read again, while the book is being exported, or while it is being read again already.
- Edit Text stops for a book you have read again in another encoding, keeps your edit as a copy, and says "Edit Text has stopped for Moby-Dick, since its file was read again. Choose Edit Text again to edit the new text."
- Edit Text, Replace Existing, and Redo Text Extraction wait while a book is read again in another encoding, and say "TextMouth is reading “Moby-Dick” again in another encoding. Try again when that finishes.", where Redo Text Extraction in Storage settings said nothing.
- A TextMouth older than 0.2.3 drops the note that an encoding was chosen: 0.2.2 reads the book in the same encoding as a guess, and 0.1.1 drops the encoding too (see [Where TextMouth keeps your library](book-packages.md)).

## 0.2.2 (October 24, 2026)
### Reading
- Go to Page… says which page of a shared label it reached, as in "Jumped to page 2, the second page labelled 2."
- Go to Page… says where the cursor is, and why, when it cannot land on the page asked for, as in "Page 7 has no words, so the cursor is on page 8." and "Page 40 is in a skipped section, so the cursor is on page 52.", where it said the page typed.
- Return in Go to Page's field, on a label that another page carries too, goes to that label's next page, and round to the first after the last, where it closed the panel and did nothing.
- A page break's number inside an EPUB or HTML heading is no longer part of the heading: "Part 9Two" is now "Part Two".
- Next Page, Previous Page, and Go to Page… do nothing while a book is still loading, where they said "This book has no pages."
- The playback bar's navigation unit pickers leave Page out for a book without pages.
- A PDF's own page label that looks like a number with a thousands separator, such as 1.100, stays as the PDF gives it, and a PDF already in your library keeps its old labels until Redo Text Extraction reads it again.
- Plain text books have pages: each form feed between words begins one, up to 100,000.
- The first time this version opens, every braille, plain text, EPUB, and HTML book is read again once, and a braille book whose new reading differs from its text keeps a copy of its old text beside it (see [Where TextMouth keeps your library](book-packages.md)).
- A plain text, Markdown, or HTML file that is neither UTF-8 nor UTF-16 and names no encoding is no longer always read as Windows-1252, since TextMouth now guesses its encoding when you add it, and books already in your library keep their text (see [What TextMouth reads](reads-text-files.md)).

### Braille
- BRF and PEF books have pages, the braille pages an embosser or a braille display counts, named by their braille page number read as print, such as 12 or p1, and Next Page, Previous Page, and Go to Page… move by them.
- A BRF has pages only when it marks them, with form feeds between its braille text or with braille page numbers that end most of its 25-line pieces, and a page with neither words nor a number is not a page.
- English Braille, American Edition is read with its italic and bold where the sign is certain, in words that start with l or n to z, in capitals and numbers, and in most contractions, and no word reads differently from before.
- An emphasized word of English Braille, American Edition that starts with a to j still reads with a stray period, one that starts with k reads with an equals sign, and one that starts with m reads with µ, as before.
- Contracted Unified English Braille reads a whole word before an emphasis end sign as the word, so "people" is no longer "p".

### Library
- Replace Existing puts the new copy in the place of the old one, keeping its reading position, bookmarks, settings, folder, and place on the reading list, and an audiobook's transcript when its audio is proven the same, where it threw them away.
- The duplicate question says what Replace Existing keeps and where the old copy's files go, in place of what it threw away, and for a text book that an edit of its text is kept beside the new text as a copy.
- When one copy is an audiobook and the other is read from its text, Replace Existing keeps only the old copy's folder and place on the reading list, and the question and the button's hint say so.
- With the Trash on, the duplicate question says that putting the old copy's files back won't return that copy to your library, and putting them back does not add it to the library again.
- An audiobook's reading position and bookmarks follow the new copy's chapters when they differ from the old copy's.
- Replace Existing waits, and says why, while the old copy is open in a reader, being transcribed, being exported, or having its audio edited, while some of its files are only in the cloud, or while TextMouth moves books between folders or rebuilds its data directory.
- Replace Existing removes the old copy's files only after the library holds the new copy, and says so if it cannot remove them.
- When Replace Existing keeps an edit of the old copy's text as a copy, VoiceOver says where it was kept.
- Edit Text says it has stopped for a book that Replace Existing replaced.
- Book Information shows a Text Encoding row, and Speak Full Info says the encoding, as in "Text encoding: Windows-1251 (Cyrillic), guessed.", for a text book whose encoding was guessed (see [The Library window](book-information.md)).
- A TextMouth older than 0.2.2 drops a guessed encoding when it saves a book, and that book's text may then read as Windows-1252 again the next time it is rebuilt (see [Where TextMouth keeps your library](book-packages.md)).

## 0.2.1 (October 23, 2026)
### Reading
- Search in Book also searches an audiobook's transcript, telling you when each match is heard and moving the audio there when you choose one, and Go Back (Command-[) returns to where you were.
- EPUBs that name a file in another letter case than their ZIP spells it now show the chapters they were missing.
- Word 97-2003 files with a table of contents or links now get every page, not only the first.
- The first time this version opens, a book open in a reader gets its new text with its pages, with the cursor on the same words, and words that an EPUB holds inside a page break are kept.
- A heading made of a number, such as "IV" or "1984", in a DAISY or EPUB book is read even where a page begins, and only a page's own number is left unread.
- A line in the text that begins with a page or chapter marker no longer hides the rest of its words.

### Listening
- Retranscribe Audio… takes the place of Transcribe Audio… once a book has a transcript, and its sheet says what it replaces and asks you to download a book that is only in iCloud first.
- A feed episode's transcript can now be edited and cleaned up, and it stays with the episode in its feed, even after its download is deleted, until you delete the episode or the feed.
- Six faults found in a review of transcription are fixed, among them edits to a transcript that were announced as taken and then lost, a damaged transcript file that could crash TextMouth, and a Clean Up that offered Apply and then refused it.
- Resume after a very quick Pause keeps your place instead of restarting the chapter.
- Seeking in a variable-bit-rate MP3 without a Xing header, whose length was only guessed, now lands where you ask and no longer moves a saved place back.
- Play pressed while a book's files are being moved now waits for the move to end, then plays from your place.
- An audio file that never finishes being read no longer leaves its book on Loading: TextMouth stops waiting after a while and says so.
- Such a file is not read again until TextMouth is opened again, so a file that hangs cannot slow TextMouth down by being opened over and over.
- A retranscription or Clean Up that fails partway leaves the transcript and its text as they were.
- The last chapter's length in an MP3 with chapter markers is measured exactly, not estimated.

### Export
- Exported Markdown, for a book's text and for a transcript, has a backslash only where Markdown needs one, and no chapter-marker lines.
- Each transcribed book's text was written again, once, the first time the book opened in this version, so that it too has a backslash only where Markdown needs one.

### Library
- The duplicate question now says what Replace Existing throws away: the old copy's reading position, bookmarks, settings, and any edit of its text or transcript.
- TextMouth now keeps the books that a later version added in a form it cannot read, as they are but not shown, instead of refusing the whole library, and Storage settings say how many there are.
- Delete Folder leaves such books, and the folders that hold them, where they are, and says so.

## 0.2.0 (October 21, 2026)
### Going back to 0.1.1
- 0.1.1 cannot read the index of a library that holds a book in any of eight kinds that 0.2.0 added: braille, rich text, rich text with attachments, Word 97-2003, OpenDocument, Word 2003 XML, Safari web archives, and SSML.
  It leaves library.json as it is, keeps a copy of it beside it, and offers Try Again and Rebuild Library Index under Recovery Options…, but it still writes each book's record.
  And those records lose what 0.2.0 added to them: the record of an edit of the book's text and of the page reader that wrote it. Back in 0.2.0, a book whose text you edited is read from its file again, and your edit is kept beside it as a copy.
- 0.1.1 was built on October 17, 2026. A build made before October 18, 2026 does not know the seven kinds added that day: rich text, rich text with attachments, Word 97-2003, OpenDocument, Word 2003 XML, Safari web archives, and SSML.
- A build made before October 20, 2026 does not know braille. Each such build finds the index unreadable when it holds a book in a kind it does not know.
- Never choose Rebuild Library Index in 0.1.1. It makes an index without the books in those eight kinds, and without the folders and the manual order that only the index held, which the copy of library.json that it keeps still has.

### Reading
- Next Page, Previous Page, and Go to Page… move by page in EPUB, PDF, Word, DAISY, and other books that have pages, and Where Am I? says the page; books already in your library gain their pages the first time this version opens.
  If a book's text differs from what TextMouth reads from its file, as after an edit made with Edit Text before this version, its old text is first kept in a copy beside it; an edit you make from now on is kept as it is.
- Rich text, Word 97-2003, OpenDocument, Safari web archive, SSML, and DTBook files can now be added as books.
- Edit Text opens a book's text in your own editor, and your reading position, bookmarks, and skipped headings stay with their words when the text changes.

### Listening
- Audio in more formats, such as AC-3, AMR, and MP2, is converted as it is added and lossless audio stays lossless; M3U playlists and Nero chapter lists are read, and a manifest.json can arrange a ZIP of tracks, which Edit Manifest changes later.
- Builds of main made before 0.2.0 read less of a manifest.json.
  Builds from October 13, 2026 arranged a ZIP's tracks by a tracks list.
  Builds from October 14, 2026 also edited an imported audiobook's manifest where it is, and imported a plain folder of tracks.
  The oldest builds read only title, author, order, and chapters, and did not import Ogg tracks.
- A title or author you changed in Book Info before October 14, 2026, and that was recorded as yours, was written into the book's manifest the first time 0.2.0 opened your library, so it stays the book's.
- New Recording records from a microphone, Edit Audio… edits an audiobook's audio from the keyboard, and Transcribe Audio… turns an audiobook into text on macOS 26 and later.
- Ogg audio is no longer played as it is, since on October 14, 2026 macOS's own Vorbis decoder locked up while TextMouth played an Ogg audiobook, TextMouth's memory grew until the Mac ran out, and the Mac had to be restarted.
- Every Ogg file is converted to .m4a as it is added, and the Ogg books already in the library were converted once, a book at a time, at the first launch of this version.
- TextMouth also stops a playback whose audio stops responding, and saves your place and quits before a fault in macOS's audio can exhaust the Mac's memory.

### Braille
- TextMouth reads BRF, BRL, and PEF braille files and writes BRF and PEF from Export, in Unified English Braille or English Braille, American Edition, contracted or not, chosen in a new Braille tab, and it keeps italic and bold where the code can carry them.
- A Language pop-up adds the braille tables of this Mac's VoiceOver, for many languages beyond English.

### Export
- Export copies a book's audio, original file, text, or transcript out of the library, and its Convert to menu makes a text book's text HTML, RTF, Word 97-2003, BRF, or PEF as well as Markdown.

### Library
- Podcasts and article feeds can be subscribed to by address or by searching Apple's podcast directory, each feed lists its episodes and articles in a folder of its own, and the newest are downloaded as you choose.
- A Reading List holds books from any folder in an order you choose and carries on from one to the next, and the Unopened and Recently Opened categories take the place of No Folder and Recent.
- A library can live in iCloud Drive, Dropbox, or Google Drive, and each book can be downloaded when you need it, removed from this Mac to free space, or kept on it.
- Add to Library, a plus button in the Library window's toolbar, opens a sheet with every way to add to the library (see [Adding books](adding-books.md)).
- Import DAISY Folder… was renamed Import Folder… on October 14, 2026, since it imports a folder of audio tracks as one audiobook too, and a key you gave it keeps working.
- Unopened took the place of No Folder on October 7, 2026, and the books in no folder are at the top of the library in Folders.
- Recently Opened was called Recent until October 10, 2026, and keeps the sort you chose for it then.
- An EPUB's author is read from a creator element, a dcterms:creator meta element, or a contributor marked as the author, since October 7, 2026.
- A creator marked as the author is preferred to one listed before it, such as an illustrator, and a creator that says only Unknown is read as naming no one.
- On October 7, 2026, 150 of a library's 729 EPUBs named their author in a meta element alone, and every one was listed under Unknown.
- The Add to Library button took the place of the Import, New from Text, and Add Feed buttons on October 17, 2026.
- Speak Info and Speak Full Info had the letter I alone, and I pressed twice, until October 17, 2026, and now follow the defaults Shift-Command-I and Shift-Command-I pressed twice quickly, unless you changed their keys.
- The three-second rule of earlier versions, under which a quick third press of Shift-Command-I reached the full summary, is gone.

## 0.1.1
- The first beta version of TextMouth. Its changes are not listed here.
