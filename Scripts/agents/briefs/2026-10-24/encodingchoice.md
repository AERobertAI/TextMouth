# Brief: choose a book's text encoding in Book Information (October 24, 2026)

You are `encodingchoice`, an Opus agent. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

Read `common.md` beside this file first. Its rules apply to you, except that this brief replaces its task list and its last line about the weekly reset.

## The request
FMT16 merged today (main 96cd2481): at import, TextMouth guesses the encoding of a text file that names none, records it on the book (`Book.textEncoding`), and Book Information shows "Text Encoding, Windows-1251 (Cyrillic), guessed". Read its TODO entry in the main checkout: `grep -n "Text files in other encodings (FMT16)" /Users/roberteggleston/programming/ai/claude/swift/TextMouth/TODO-2026-09-04.md`.

A guess can be missed or wrong, and there is no way to fix it. The user (October 24): "Go ahead and do the reopening with a different encoding … can it be set in the info screen for a book with the current one selected in the popup?"

## The design
1. **One control.** Book Information's "Text Encoding" row becomes a pop-up button, with the encoding the book is read in now selected. Add no menu command: the user's standing rule is that a new command must not duplicate an existing one.
2. **Which books.** Every book whose text TextMouth reads from a text file the user added: plain text, Markdown, and HTML (`BookFormat.usesTextFileDecoder`). Not feed articles, recordings, or text typed in.
   - Show what the book is read in now: the guess, a choice, the file's own declaration, Unicode (a byte order mark, or valid UTF-8), or the Windows-1252 default.
   - Work it out without making the sheet wait on a large file.
3. **The options.**
   - "Automatic" comes first. It is TextMouth's own reading at import: a declaration or Unicode, then the guess, then Windows-1252.
   - Then UTF-8, then the catalog's encodings in `TextEncodingCatalog`'s order, named exactly as the catalog names them.
4. **Choosing another encoding.**
   - First, a confirmation alert says plainly what changes, for example: "Read “Title” again as Shift JIS (Japanese)? Its text is replaced by the new reading." Add what happens to places, and to an edit, if it has one. Cancel leaves everything, and the pop-up, as it was.
   - Then the book's text is read again from its file in that encoding.
   - **Strict decoding only:** a file whose bytes are not valid in the chosen encoding is refused with a sentence naming the encoding, and nothing changes. No byte is ever dropped or replaced; `TextFileDecoder` already guarantees that.
5. **The re-read.** Use the existing machinery for one book (what Redo Text Extraction or the launch re-read uses), with all its protections:
   - **Places and bookmarks** move with the text (T06). Find out, and say in the alert and in your report, what happens to a place whose words can't be found in the new reading, which is likely when garbled text becomes Cyrillic.
   - **An Edit Text change** is kept beside the new text as a `content.md.edited-` copy, and VoiceOver says so, as Replace Existing does.
   - **An open reader** shows the new text, as it does after the launch re-read.
   - **Busy books.** Refuse while the book is being edited, exported, moved, or is partly only in the cloud. Reuse Replace Existing's refusal checks and sentences where they fit, rather than repeating them (DRY).
6. **The record.**
   - `Book.textEncoding` holds the choice.
   - Book Information and Speak Full Info tell a guess from a choice, for example "Windows-1251 (Cyrillic), chosen", in words that stay clear when VoiceOver speaks them.
   - "Automatic" clears the choice and records the guess, if there is one.
   - If this needs a new on-disk field or value form: decode it leniently, leave it out when unset, and update `OnDiskContractTests`' pins in the same commit, giving the reason.
   - An older TextMouth drops new keys. Say in your report what that does to a chosen encoding.
7. **VoiceOver.**
   - The pop-up is labelled "Text Encoding".
   - Its value names the encoding, and whether it was guessed or chosen.
   - Test it with the hosted accessibility helpers (call `skipUnlessHostedWindowsExposeAccessibility()` first), and run `make lint-a11y`.

Out of scope:
- **Braille files.** BRF and BRL are braille ASCII, a fixed code with nothing to guess.
- **Feed articles.**

## Setup
- Your worktree is made from main. Run `git checkout -b formats/encoding-choice main`, and check that `git merge-base --is-ancestor 96cd2481 HEAD` succeeds.
- You own:
  - Book Information's encoding row (`LibrarySheetViews.swift`, `LibraryInfoWording.swift`);
  - the decoder's policy (`TextFileDecoder.swift`);
  - the new view model code;
  - their tests.

  Agree on the board before you touch other shared files.

## Tests
Each change gets its tests:
- a refused decode;
- a re-read in a chosen encoding, with places moved, and with places whose words are gone;
- Automatic putting the guess back;
- an edit kept as a copy;
- each refusal;
- the record's round trip, and older records loading;
- the words of the row, the alert, and Speak Full Info;
- VoiceOver's label and value.

## At the end
In one `run-area.py` invocation, run your touched classes and the import, library, sheets, reader-text, and analysis areas, plus `make lint-tests LINT_BASE=main` and `make lint-a11y`. Delete your build folder, unregistering its app first as `common.md` says.

## Your report (at most 25 lines)
- Each commit.
- The counts and the lint results.
- Every sentence a listener hears that is new or changed, in full.
- What happens to places whose words are gone.
- Anything unfinished, and the follow-ups.
