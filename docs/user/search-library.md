# Search Library

Part of [TextMouth's documentation](../../README.md).

- Edit > Find > Search Library… (Option-Command-F) opens a window that finds a word, a phrase, or a pattern in the text of every book in the library at once. It works in every window, a reader's and a Library window's alike, and from the Search Library window itself.
- The command is also in the Shortcuts tab of Settings, last in the Library group, as "Search Library…", and works in every window. Option-Command-F is no other default shortcut, menu command, or system command. Command-F is still Search in Book's in a reader, and Shift-Command-F is still Add Feed's in the Library window.
- Search in Book (see [Reader windows](reader-windows.md)) looks in one book. Search Library looks in all of them, and shares its way of matching, so a word found in one is found in the other.

## The window

- The window is called "Search Library". There is one, whichever window opened it. The search field takes the keyboard each time the window opens.
- Closing the window keeps its query, its options, and its results, and opening it again shows them. A search that closing cut off runs again when the window opens.
- What VoiceOver reaches, in order:
  - The search field, "Search the library", with the hint "Type to search the text of every book in the library". Its placeholder is "Text to find in every book".
  - The status line, which VoiceOver reads in place and hears once, as a search ends.
  - The checkboxes Match Case and Regular Expression.
  - Close, which Escape presses. Its hint is "Close Search Library; its results stay for the next time it opens".
  - While a search runs, a progress bar, "Search progress", and a Stop button (Command-Period, hint "Stops the search, keeping the matches found so far").
  - The results, a list labelled "Results".
- Searching begins when you stop typing for a moment (about a third of a second), and begins again when you change an option. A newer search stops an older one.
- Return in the search field moves to the first result.

## Match Case and Regular Expression

- Match Case is unchecked unless you check it. Unchecked, capital and small letters match each other, with the full folding of Unicode: "STRASSE" finds "Straße". Checked, a match must have the same capital and small letters. Either way, a letter with an accent written as one character matches the same letter written as a base letter and a combining mark.
- A search matches whole characters: "e" does not find the e inside "é" written as e and a combining mark, and a word with a soft hyphen or a zero-width space inside it is not found by its plain spelling.
- Regular Expression, unchecked unless you check it, makes the search text an ICU regular expression, the kind Search in Book takes. Matches may cross line ends. A pattern that is not valid says so in the status line, as "Invalid regular expression:" and the reason.
- Search in Book has the same Match Case checkbox, unchecked unless you check it, with the hint "When checked, a match must have the same capital and small letters as the search text".

## What is searched

- Search Library searches the text of each book as the reader shows it: the words of its chapters, without the Markdown marks, the links' addresses, or the page and chapter markers that the book's text file holds. A match is therefore a phrase the reader would speak, and opening it goes to those words.
- It searches the books of the library, in the order of their titles. A feed's articles and episodes are not searched, as the Library's lists leave them out. An audiobook is searched only when it has text, such as a transcript.
- A book whose text is only in the cloud is not searched, and never downloaded for the search. The status says how many were left out.
- A book whose text cannot be read is left out too, and the status says so.

## The status line

- Before anything is typed: "Type text to find in every book of the library."
- While a search runs: "Searching 750 books…", then "Searched 120 of 750 books…". When a book has to be prepared on the way, as described below, "Preparing 120 of 737 books…".
- When it ends, it says what it found: "No matches", "1 match in 1 book", or "212 matches in 31 books". A book that holds more matches than it keeps makes the count "More than 41,000 matches in 750 books".
- Notes follow after semicolons: what the list leaves out ("showing up to 20 in each book, and 1,000 in all"), "3 books in the cloud weren't searched", and "1 book couldn't be read".
- A search you stop says "Stopped after 120 of 750 books:" and then what it had found.
- When the library has no book with text, it says "No book in the library has text to search."

## The results

- The results are a list grouped by book. Each book's heading, which VoiceOver reads as a heading, gives its title, its author unless none is known, and how many matches it holds: "The Long Road, by Ines Okonkwo-Varga: 12 matches", or "more than 1,000 matches" for a book with more.
- Under it, each match is a row that shows the words around the match and, under them, where it is: the heading it is under or its chapter.
- VoiceOver reads a row as the match in its context first, then where it is, then the book, as in "…the garden window looked…, Chapter 3, in The Long Road", with the hint "Opens the book at this match". The context comes first so that moving from row to row you hear what differs first, and the book comes last so that a row is never heard without it.
- Return, a double-click, or VoiceOver's default action opens a match. A context menu on a match offers the same.
- The Books rotor moves from book to book, and the Matches rotor from match to match, each stopping on the words the list reads.
- The list keeps its limits so that it stays usable: a book keeps its first 100 matches and counts up to 1,000, the list shows 20 for each book and 1,000 in all, and a book with more ends with a row "Show all 212 matches in The Long Road". Choosing it lists up to 500 of that book's matches, as Search in Book does; for a book with more than that the row reads "Show the first 500 of 700 matches in The Long Road", VoiceOver says "Listing the first 500 of 700 matches in The Long Road", and a last row says "Listing 500 of 700 matches: refine the search to see the rest". The book's heading keeps its real count when Show All has seen every match.

## Opening a match

- Opening a match opens the book in its reader window, or brings its open window forward, and moves the reader to the match. The reader looks again in its own text with the same matching, so that an edit of the text since the search, or a rebuilt text, still lands on the nearest match.
- Once the reader's window is in front, a moment after the move, VoiceOver says "Moved to the match, Chapter 3." or "Moved to the match.". It says "The text changed since the search; moved to the nearest match." when it had to look again, and "That match is no longer in the book's text. Search again to find it." when nothing is left to find. A book removed from the library since the search says "<title> is no longer in the library."
- Go Back (Command-[) in that reader returns to where it was before the move: for a book that was not open, the place it opened at, its saved reading position.
- Nothing is spoken if the reader has closed, has taken a later match, or Go Back has already undone the move.

## The first search, and the search texts

- Searching a library of 750 books in a second or two is possible because TextMouth keeps the text of each book, ready to search, in a store of this Mac's own, outside the library: the folder Search Text in ~/Library/Caches/com.textmouth.TextMouth (see [Where TextMouth keeps your library](where-your-library-lives.md)). The store holds about as much as the library's text: on the library it was measured on, 676 MB of text made 650 MB.
- TextMouth makes the store in the background after the first launch of a new installation, once the launch's other work has ended, at the lowest priority, two books at a time. It never downloads a book, it is not done in Low Power Mode, and it stops while the data directory moves or the disk has no room. Opening the Search Library window starts a pass if none is running, and a search pauses it while it runs.
- Each time you launch TextMouth afterwards, the pass looks at each book and makes the text of the books that have none or whose text has changed. Edit Text, a book read again, Redo Text Extraction, and a sync all change a book's text, so its search text is made again.
- A search that meets a book with no search text made yet makes it itself, and says "Preparing 120 of 737 books…". That is the slow case: the first search ever, within about a minute of the first launch of a new installation, took 8 seconds for 737 books. With the store made, a plain search of those books took under a second, Match Case the same, and a regular expression about 2.5 seconds (measured on November 13, 2026, on the library of 737 books and 676 MB it was built for).
- The store is made again for every new build of TextMouth, since a new build may read books differently, and whenever macOS empties the Caches folder, which it may do when the disk runs low. Time Machine leaves Caches out. Making the store again takes about 51 seconds of processor time, spread over the background pass, and writes about as much as the library's text.
- The store keeps the free space reserve that imports keep, 1 GB: when a text would leave the disk with less, it is not kept, and the search works from the parse it made. A search or a pass that finishes removes the texts of books no longer in the library, and of another data directory's books.
- The debug log has one line for each background pass, LIBRARY_SEARCH_PREPARATION, with counts only (see [Where TextMouth keeps your library](where-your-library-lives.md)).

## What Search Library does not do

- It does not search a feed's articles or episodes, or the text of a book in the cloud that is not on this Mac.
- On the iPhone, Search in Book has no Match Case checkbox yet, and there is no Search Library screen.
- It searches the whole library; a search of one folder or view is not built.
- A match in a transcribed audiobook is named by the transcript chapter's own title and gives no time, where Search in Book names the audio chapter and gives the time. Opening it moves the reader to the sentence that holds it, as Search in Book does.
